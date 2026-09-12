import SwiftUI
import simd

/// Colour per entity kind. The policy's default ontology has seven kinds;
/// anything else falls back to a stable hash so custom kinds stay consistent
/// between renders.
enum EntityPalette {
    static func color(for kind: String) -> Color {
        switch kind.lowercased() {
        case "person":       return Color(red: 0.72, green: 0.52, blue: 0.30)
        case "organization": return Color(red: 0.36, green: 0.47, blue: 0.65)
        case "place":        return Color(red: 0.36, green: 0.60, blue: 0.47)
        case "event":        return Color(red: 0.71, green: 0.42, blue: 0.42)
        case "work":         return Color(red: 0.55, green: 0.45, blue: 0.68)
        case "concept":      return Color(red: 0.68, green: 0.60, blue: 0.38)
        case "other":        return Color(red: 0.50, green: 0.50, blue: 0.52)
        default:
            let hue = Double(abs(kind.hashValue) % 360) / 360.0
            return Color(hue: hue, saturation: 0.35, brightness: 0.60)
        }
    }
}

/// Renders the layout in a single `Canvas` pass and handles pan, zoom, click
/// and drag. Nodes are not views — a 200-node SwiftUI hit-test tree would be
/// far slower than inverting one transform.
struct GraphCanvasView: View {
    @ObservedObject var simulation: GraphSimulation

    @Binding var selection: GraphSelection?
    var onExpand: (String) -> Void

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panAnchor: CGSize = .zero
    @State private var draggingNode: Int?

    /// Below this zoom, edge predicates are omitted — otherwise a dense graph
    /// renders as unreadable overlapping text.
    private let labelZoomThreshold: CGFloat = 0.75

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                var context = context
                context.translateBy(x: pan.width, y: pan.height)
                context.scaleBy(x: zoom, y: zoom)
                draw(in: &context)
            }
            .background(Color.sewnBG)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .gesture(magnifyGesture)
            .onTapGesture(count: 2) { location in
                if let index = hitTest(location),
                   simulation.layout.nodes.indices.contains(index) {
                    onExpand(simulation.layout.nodes[index].id)
                }
            }
            .onTapGesture { location in
                select(at: location)
            }
            .onAppear { simulation.resize(to: geo.size) }
            .onChange(of: geo.size) { _, newSize in simulation.resize(to: newSize) }
            .overlay(alignment: .bottomTrailing) { controls }
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext) {
        let layout = simulation.layout

        // Edges first so nodes sit on top of their connections.
        for edge in layout.edges {
            guard layout.position.indices.contains(edge.a),
                  layout.position.indices.contains(edge.b) else { continue }
            let a = point(layout.position[edge.a])
            let b = point(layout.position[edge.b])

            let isSelected = selection?.edgeId == edge.id
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)

            context.stroke(
                path,
                with: .color(isSelected ? Color.sewnGold : Color.sewnInk.opacity(0.18)),
                lineWidth: isSelected ? 2.0 : min(0.7 + Double(edge.weight) * 0.35, 3.5)
            )

            if zoom >= labelZoomThreshold, !edge.predicate.isEmpty {
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let label = Text(edge.predicate)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color.sewnInk.opacity(isSelected ? 0.75 : 0.38))
                context.draw(context.resolve(label), at: mid, anchor: .center)
            }
        }

        // Nodes.
        for index in layout.nodes.indices {
            let node = layout.nodes[index]
            let center = point(layout.position[index])
            let radius = self.radius(for: node)
            let isSelected = selection?.entityId == node.id
            let color = EntityPalette.color(for: node.kind)

            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            context.fill(circle, with: .color(color.opacity(isSelected ? 0.95 : 0.72)))
            context.stroke(
                circle,
                with: .color(isSelected ? Color.sewnInk.opacity(0.75) : color.opacity(0.9)),
                lineWidth: isSelected ? 2 : 1
            )

            // A pinned node keeps a ring so the state is visible at a glance.
            if layout.pinned[index] {
                let ring = Path(ellipseIn: CGRect(
                    x: center.x - radius - 4, y: center.y - radius - 4,
                    width: (radius + 4) * 2, height: (radius + 4) * 2
                ))
                context.stroke(ring, with: .color(Color.sewnGold.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }

            let label = Text(node.name)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(Color.sewnInk.opacity(0.85))
            context.draw(context.resolve(label),
                         at: CGPoint(x: center.x, y: center.y + radius + 9),
                         anchor: .center)
        }
    }

    /// Mention count drives size, so hubs read as hubs.
    private func radius(for node: GraphLayout.Node) -> CGFloat {
        let base = 9.0
        return CGFloat(min(base + log(Double(max(node.mentionCount, 1))) * 5.0, 26.0))
    }

    private func point(_ value: SIMD2<Double>) -> CGPoint {
        CGPoint(x: value.x, y: value.y)
    }

    // MARK: - Hit testing

    /// Invert the pan/zoom transform, then ask the layout for the nearest node.
    private func layoutPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(
            x: (location.x - pan.width) / zoom,
            y: (location.y - pan.height) / zoom
        )
    }

    private func hitTest(_ location: CGPoint) -> Int? {
        simulation.layout.node(at: layoutPoint(location), radius: 26)
    }

    private func select(at location: CGPoint) {
        let layout = simulation.layout
        if let index = hitTest(location), layout.nodes.indices.contains(index) {
            selection = .entity(layout.nodes[index].id)
            return
        }
        if let edge = nearestEdge(to: layoutPoint(location)) {
            selection = .relationship(edge)
            return
        }
        selection = nil
    }

    private func nearestEdge(to point: CGPoint, tolerance: Double = 6) -> String? {
        let layout = simulation.layout
        let target = SIMD2(Double(point.x), Double(point.y))
        var best: (id: String, distance: Double)?

        for edge in layout.edges {
            guard layout.position.indices.contains(edge.a),
                  layout.position.indices.contains(edge.b) else { continue }
            let a = layout.position[edge.a]
            let b = layout.position[edge.b]
            let ab = b - a
            let lengthSquared = simd_length_squared(ab)
            guard lengthSquared > 0 else { continue }
            let t = max(0, min(1, simd_dot(target - a, ab) / lengthSquared))
            let distance = simd_distance(target, a + ab * t)
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance { best = (edge.id, distance) }
        }
        return best?.id
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if draggingNode == nil {
                    draggingNode = hitTest(value.startLocation) ?? -1
                    if draggingNode == -1 { panAnchor = pan }
                }
                if let index = draggingNode, index >= 0 {
                    simulation.drag(index, to: layoutPoint(value.location))
                } else {
                    pan = CGSize(
                        width: panAnchor.width + value.translation.width,
                        height: panAnchor.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in draggingNode = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(max(value.magnification * zoom, 0.25), 3.0)
            }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 6) {
            if !simulation.layout.isSettled {
                ProgressView().scaleEffect(0.4).frame(width: 14, height: 14)
            }
            control("minus.magnifyingglass") { zoom = max(zoom / 1.25, 0.25) }
            control("plus.magnifyingglass") { zoom = min(zoom * 1.25, 3.0) }
            control("arrow.counterclockwise") {
                zoom = 1
                pan = .zero
                simulation.reheat()
            }
        }
        .padding(7)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sewnBorder, lineWidth: 1))
        .padding(14)
    }

    private func control(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.sewnInk.opacity(0.55))
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.plain)
    }
}

/// What the inspector is currently showing.
enum GraphSelection: Equatable {
    case entity(String)
    case relationship(String)

    var entityId: String? {
        if case .entity(let id) = self { return id }
        return nil
    }

    var edgeId: String? {
        if case .relationship(let id) = self { return id }
        return nil
    }
}
