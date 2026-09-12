import Foundation
import simd

/// Force-directed layout over the knowledge graph.
///
/// Deliberately free of SwiftUI so the physics can be reasoned about and tested
/// on its own. Storage is parallel arrays indexed by ordinal rather than a
/// graph of reference types: `/v1/graph` caps at `limit` entities, so this runs
/// over tens to low hundreds of nodes, where an O(n²) repulsion pass is well
/// inside a frame budget and a quadtree would be premature.
struct GraphLayout {

    struct Node {
        let id: String
        var name: String
        var kind: String
        var mentionCount: Int
        var documentIds: [String]
    }

    struct Edge {
        let id: String
        var a: Int
        var b: Int
        var predicate: String
        var weight: Int
        var documentIds: [String]
    }

    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []
    private(set) var ordinal: [String: Int] = [:]

    var position: [SIMD2<Double>] = []
    var velocity: [SIMD2<Double>] = []
    var pinned: [Bool] = []

    /// Simulation temperature. Decays toward zero; the driver stops ticking
    /// once it falls below `restThreshold` so a settled graph costs nothing.
    private(set) var alpha: Double = 0

    var bounds: CGSize = CGSize(width: 900, height: 650)

    static let restThreshold = 0.001

    var isSettled: Bool { alpha < Self.restThreshold }
    var isEmpty: Bool { nodes.isEmpty }

    // MARK: - Tuning

    private let damping = 0.85
    private let gravity = 0.012
    /// Caps any single pair's contribution so coincident nodes can't launch
    /// each other off the canvas.
    private let maxPairForce = 1_200.0

    private var idealDistance: Double {
        let area = Double(bounds.width * bounds.height)
        return sqrt(area / Double(max(nodes.count, 1)))
    }

    private var center: SIMD2<Double> {
        SIMD2(Double(bounds.width) / 2, Double(bounds.height) / 2)
    }

    // MARK: - Building

    /// Replace the layout wholesale. Used when the seed changes — a new query
    /// is a new picture, so there is nothing to preserve.
    mutating func reset(with response: GraphResponseDTO) {
        nodes = []
        edges = []
        ordinal = [:]
        position = []
        velocity = []
        pinned = []
        alpha = 1.0
        ingest(response, seededAt: nil)
    }

    /// Merge an expansion into the existing layout.
    ///
    /// This is the operation that makes traversal feel stable: nodes already on
    /// screen keep their position and velocity, new nodes are seeded next to
    /// whichever node was expanded, and `alpha` is only nudged rather than
    /// reset — so the graph settles around the arrivals instead of re-solving
    /// from scratch.
    mutating func merge(_ response: GraphResponseDTO, expandedFrom entityId: String?) {
        ingest(response, seededAt: entityId.flatMap { ordinal[$0] })
        alpha = max(alpha, 0.3)
    }

    private mutating func ingest(_ response: GraphResponseDTO, seededAt anchor: Int?) {
        let anchorPosition = anchor.map { position[$0] } ?? center

        for entity in response.entities {
            if let index = ordinal[entity.id] {
                // Already on screen — refresh the label data, leave the physics.
                nodes[index].name = entity.name
                nodes[index].kind = entity.kind
                nodes[index].mentionCount = entity.mentionCount
                nodes[index].documentIds = entity.documentIds
                continue
            }
            let index = nodes.count
            ordinal[entity.id] = index
            nodes.append(Node(
                id: entity.id,
                name: entity.name,
                kind: entity.kind,
                mentionCount: entity.mentionCount,
                documentIds: entity.documentIds
            ))
            position.append(anchorPosition + Self.jitter())
            velocity.append(.zero)
            pinned.append(false)
        }

        var known = Set(edges.map(\.id))
        for relationship in response.relationships {
            guard known.insert(relationship.id).inserted,
                  let a = ordinal[relationship.subjectId],
                  let b = ordinal[relationship.objectId],
                  a != b else { continue }
            edges.append(Edge(
                id: relationship.id,
                a: a,
                b: b,
                predicate: relationship.predicate,
                weight: relationship.weight,
                documentIds: relationship.documentIds
            ))
        }
    }

    /// A small random offset so co-seeded nodes don't start exactly on top of
    /// each other (which would make the repulsion direction undefined).
    private static func jitter() -> SIMD2<Double> {
        SIMD2(Double.random(in: -24...24), Double.random(in: -24...24))
    }

    // MARK: - Mutation reconciliation

    /// Drop a node by entity id. Rename, merge and set-kind all *re-key* the
    /// entity server-side, so the id the client held is no longer valid and the
    /// stale node has to go before the re-query brings back the survivor.
    mutating func removeNode(id: String) {
        guard let index = ordinal[id] else { return }
        nodes.remove(at: index)
        position.remove(at: index)
        velocity.remove(at: index)
        pinned.remove(at: index)

        edges.removeAll { $0.a == index || $0.b == index }
        for i in edges.indices {
            if edges[i].a > index { edges[i].a -= 1 }
            if edges[i].b > index { edges[i].b -= 1 }
        }

        ordinal.removeAll()
        for (i, node) in nodes.enumerated() { ordinal[node.id] = i }
        reheat()
    }

    mutating func removeEdge(id: String) {
        edges.removeAll { $0.id == id }
        reheat()
    }

    mutating func reheat(to value: Double = 0.3) {
        alpha = max(alpha, value)
    }

    // MARK: - Interaction

    func node(at point: CGPoint, radius: Double = 26) -> Int? {
        let target = SIMD2(Double(point.x), Double(point.y))
        var best: (index: Int, distance: Double)?
        for index in nodes.indices {
            let distance = simd_distance(position[index], target)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    mutating func drag(_ index: Int, to point: CGPoint) {
        guard position.indices.contains(index) else { return }
        position[index] = SIMD2(Double(point.x), Double(point.y))
        velocity[index] = .zero
        pinned[index] = true
        reheat(to: 0.15)
    }

    mutating func setPinned(_ index: Int, _ value: Bool) {
        guard pinned.indices.contains(index) else { return }
        pinned[index] = value
        if !value { reheat(to: 0.2) }
    }

    // MARK: - Simulation

    /// Advance one tick. Fruchterman–Reingold repulsion and attraction, plus a
    /// weak pull to centre so disconnected components don't drift off screen.
    mutating func step() {
        let count = nodes.count
        guard count > 0, !isSettled else { return }

        let k = idealDistance
        let kSquared = k * k
        var displacement = [SIMD2<Double>](repeating: .zero, count: count)

        // Repulsion — every pair.
        if count > 1 {
            for i in 0..<(count - 1) {
                for j in (i + 1)..<count {
                    var delta = position[i] - position[j]
                    var distance = simd_length(delta)
                    if distance < 0.01 {
                        delta = Self.jitter()
                        distance = simd_length(delta)
                        if distance < 0.01 { continue }
                    }
                    let force = min(kSquared / distance, maxPairForce)
                    let push = (delta / distance) * force
                    displacement[i] += push
                    displacement[j] -= push
                }
            }
        }

        // Attraction — springs along edges. A heavily-observed triple pulls
        // tighter than a one-off, which is what makes clusters legible.
        for edge in edges {
            var delta = position[edge.a] - position[edge.b]
            let distance = simd_length(delta)
            guard distance > 0.01 else { continue }
            delta /= distance
            let strength = 1 + log(Double(max(edge.weight, 1)))
            let force = min((distance * distance) / k * strength, maxPairForce)
            let pull = delta * force
            displacement[edge.a] -= pull
            displacement[edge.b] += pull
        }

        // Centering.
        for i in 0..<count {
            displacement[i] += (center - position[i]) * gravity * k
        }

        // Integrate. Step length is bounded by alpha, so motion shrinks as the
        // layout cools rather than jittering forever.
        let maxStep = 0.08 * Double(min(bounds.width, bounds.height)) * alpha
        for i in 0..<count where !pinned[i] {
            velocity[i] = (velocity[i] + displacement[i] * 0.0016) * damping
            let length = simd_length(velocity[i])
            if length > 0 {
                position[i] += velocity[i] / length * min(length, maxStep)
            }
            position[i] = clampToBounds(position[i])
        }

        alpha *= 0.98
        if alpha < Self.restThreshold { alpha = 0 }
    }

    private func clampToBounds(_ point: SIMD2<Double>) -> SIMD2<Double> {
        let margin = 30.0
        return SIMD2(
            min(max(point.x, margin), Double(bounds.width) - margin),
            min(max(point.y, margin), Double(bounds.height) - margin)
        )
    }

    /// Re-centre and re-scale after the canvas resizes.
    mutating func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let old = bounds
        bounds = size
        guard old.width > 0, old.height > 0, !position.isEmpty else { return }
        let scale = SIMD2(Double(size.width / old.width), Double(size.height / old.height))
        for i in position.indices {
            position[i] = clampToBounds(position[i] * scale)
        }
        reheat(to: 0.15)
    }
}
