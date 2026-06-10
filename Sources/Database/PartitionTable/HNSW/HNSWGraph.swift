//
//  HNSWGraph.swift
//  database-server
//
//  Created by Ritesh Pakala on 3/7/26.
//

import Foundation
import MLXAccelerate

/// Internal ANN candidate used during HNSW graph traversal.
/// Not part of the public API — scoped to this file only.
fileprivate struct HNSWCandidate {
    var index: Int
    var distance: Float
}

fileprivate extension Array where Element == HNSWCandidate {
    /// Insert `element` into a distance-ascending sorted array using binary search. O(N).
    /// Used only for the bounded `results` array in beamSearch (size ≤ efSearch).
    mutating func insertSorted(_ element: HNSWCandidate) {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].distance < element.distance { lo = mid + 1 } else { hi = mid }
        }
        insert(element, at: lo)
    }
}

/// Binary min-heap for `HNSWCandidate` keyed on distance.
/// Replaces the sorted-array frontier in `beamSearch`, turning O(N) removeFirst
/// into O(log N) removeMin and O(N) insertSorted into O(log N) insert.
private struct HNSWMinHeap {
    private var storage: [HNSWCandidate] = []

    var isEmpty: Bool { storage.isEmpty }

    mutating func insert(_ element: HNSWCandidate) {
        storage.append(element)
        siftUp(from: storage.count - 1)
    }

    /// Remove and return the candidate with the smallest distance.
    /// Precondition: the heap must not be empty.
    ///
    /// One-element safety: `min` is captured by value before `removeLast()` empties
    /// `storage`, so the `if !storage.isEmpty` guard correctly skips the `storage[0]`
    /// write that would otherwise be an out-of-bounds access.
    mutating func removeMin() -> HNSWCandidate {
        precondition(!storage.isEmpty, "HNSWMinHeap.removeMin called on empty heap")
        let min = storage[0]
        let last = storage.removeLast()
        if !storage.isEmpty {
            storage[0] = last
            siftDown(from: 0)
        }
        return min
    }

    private mutating func siftUp(from i: Int) {
        var child = i
        while child > 0 {
            let parent = (child - 1) >> 1
            guard storage[child].distance < storage[parent].distance else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from i: Int) {
        let n = storage.count
        var parent = i
        while true {
            let l = 2 * parent + 1
            let r = l + 1
            var smallest = parent
            if l < n && storage[l].distance < storage[smallest].distance { smallest = l }
            if r < n && storage[r].distance < storage[smallest].distance { smallest = r }
            if smallest == parent { break }
            storage.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

// MARK: - HNSWGraph

/// Hierarchical Navigable Small World (HNSW) proximity graph over a set of partitions.
///
/// Used as both the global graph (all partitions across all owners) and as a per-user
/// personal graph. The distinction is purely in storage and lifecycle — not in type.
///
/// **Structure**
/// Multi-layer proximity graph. Every node lives at layer 0 (the dense base layer);
/// a node randomly assigned level L also lives in layers 1…L. Upper layers act as coarse
/// express lanes. Each node's `neighbors[l]` array is the literal hint for layer-l traversal —
/// search cascades from the top layer down, following those hints at each step.
///
/// **Phase 3 — Memory-Mapped Vectors**
/// Node embeddings are no longer stored in memory per-node. Instead, `vectorStore` holds
/// a memory-mapped binary file (`shard-{nodeId}-vectors` or `personal/{ownerId}-vectors`).
/// Distance computation reads directly from the mmap'd region via `VectorAccessor`.
/// The OS page cache serves as the working-set buffer — only the ~1–5% of nodes touched
/// per query occupy physical RAM.
///
/// **Lifecycle**
/// 1. `add(partition:)` inserts immediately — no warm-up buffer, no training phase.
/// 2. `remove(documentId:)` marks nodes deleted in O(1) (lazy deletion).
/// 3. `search(queryEmbedding:k:)` descends from `maxLevel` to layer 0 and returns
///    top-k candidates alongside a `SearchTrace` for diagnostic logging.
struct HNSWGraph: Codable {

    // MARK: - Node

    /// A single node in the HNSW proximity graph.
    struct Node: Codable {
        /// ID of the partition this node represents. Used for O(1) lookup in
        /// `partitionLookup` and for content resolution via `PartitionTable.indices`.
        var partitionId: String
        /// ID of the document this partition belongs to. Stored directly on the
        /// node for O(1) deletion scans — avoids a round-trip through `indices`.
        var documentId: String
        /// Index of this node's embedding in the companion vector file.
        /// Used to compute the byte offset into the mmap'd region.
        var vectorIndex: Int
        /// Highest layer this node participates in.
        var level: Int
        /// `neighbors[l]` = indices of this node's connections at layer `l`.
        /// Max connections: `2×M` at layer 0, `M` at layers 1+.
        var neighbors: [[Int]]
        /// Lazy deletion flag. Deleted nodes are skipped during search but
        /// kept in the graph so existing edges remain valid.
        var isDeleted: Bool = false

        enum CodingKeys: String, CodingKey {
            case partitionId, documentId, vectorIndex, level, neighbors, isDeleted
            // Embedding data lives in the companion binary vector file — never in the plist.
        }
    }

    // MARK: - Search diagnostics

    /// Diagnostic snapshot returned alongside every search result.
    /// Log this in `PartitionTable` to verify the graph is traversing correctly.
    struct SearchTrace {
        /// Total nodes in the graph at query time (includes deleted).
        var graphNodes: Int
        /// Highest layer currently in the graph.
        var graphMaxLevel: Int
        /// Greedy hops taken per upper layer during the cascade (index 0 = topmost layer).
        /// Empty if the graph has only one layer (all nodes at layer 0).
        var upperLayerHops: [Int]
        /// Distinct nodes visited during the base-layer (layer 0) beam search.
        var layer0Explored: Int
        /// Live (non-deleted) candidates before the distance threshold filter.
        var candidatesBeforeFilter: Int
        /// The `effectiveThreshold` applied to filter candidates.
        var threshold: Float
        /// Effective ef used for the base-layer beam search: max(k, efSearch).
        var efUsed: Int
    }

    // MARK: - Vector store (Phase 3 — not Codable, not serialised)

    /// Memory-mapped binary vector file for this graph shard.
    ///
    /// Set by `TableMutator` (global shard) or `PersonalHNSWMutator` (personal graphs)
    /// after decoding the topology from disk. Never serialised — the vector file is
    /// the persistence layer; no in-memory `Data` buffer is kept.
    ///
    /// All struct copies (e.g., `PartitionTable` snapshots) share the same class
    /// reference; this is intentional — reads from snapshots access the live mmap data.
    var vectorStore: HNSWVectorStore? = nil

    // MARK: - Stored state

    var nodes: [Node] = []

    /// Index of the graph's global entry point — always the highest-level node.
    var entryPoint: Int = -1

    /// Highest level currently in the graph.
    var maxLevel: Int = -1

    // MARK: - Hyperparameters

    /// Max bidirectional connections per node per layer (`2×M` at layer 0).
    var M: Int = 16

    /// Beam width during graph construction.
    var efConstruction: Int = 200

    /// Beam width during search queries.
    var efSearch: Int = 150

    // MARK: - Lookup

    /// Partition ID → node index. Enables O(1) targeted deletion.
    var partitionLookup: [String: Int] = [:]

    // MARK: - Threshold

    /// Adaptive squared-L2 distance threshold calibrated incrementally from inserted embeddings.
    var effectiveThreshold: Float = Float.infinity

    // MARK: - Adaptive efSearch

    var efSearchMin: Int = 50
    var efSearchMax: Int = 800

    /// Exponential moving average of observed layer-0 exploration depths.
    var emaExplored: Float = 0

    // MARK: - Counters

    var totalInsertions: Int = 0
    var totalDeletions: Int = 0
    var lastInsertedLevel: Int = 0

    // MARK: - Codable

    /// `vectorStore` and `pendingWALRecords` are intentionally absent — they are
    /// runtime-only fields managed by the owning mutator.
    enum CodingKeys: String, CodingKey {
        case nodes, entryPoint, maxLevel
        case M, efConstruction, efSearch
        case partitionLookup, effectiveThreshold
        case efSearchMin, efSearchMax, emaExplored
        case totalInsertions, totalDeletions, lastInsertedLevel
    }

    // MARK: - WAL records (Phase 4 — not Codable, not persisted in checkpoint)

    /// Topology mutations accumulated during the current operation.
    ///
    /// The owning mutator (`TableMutator`, `PersonalHNSWMutator`) drains this buffer
    /// immediately after each mutation and writes the records to the WAL file. The buffer
    /// is always empty in the persisted topology checkpoint and in snapshots.
    var pendingWALRecords: [TopologyWALRecord] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decode([Node].self, forKey: .nodes)
        // vectorStore is populated by the owning mutator after decode.

        entryPoint         = try c.decode(Int.self,            forKey: .entryPoint)
        maxLevel           = try c.decode(Int.self,            forKey: .maxLevel)
        M                  = try c.decode(Int.self,            forKey: .M)
        efConstruction     = try c.decode(Int.self,            forKey: .efConstruction)
        efSearch           = try c.decode(Int.self,            forKey: .efSearch)
        partitionLookup    = try c.decode([String: Int].self,  forKey: .partitionLookup)
        effectiveThreshold = try c.decode(Float.self,          forKey: .effectiveThreshold)
        totalInsertions    = try c.decodeIfPresent(Int.self,   forKey: .totalInsertions)   ?? 0
        totalDeletions     = try c.decodeIfPresent(Int.self,   forKey: .totalDeletions)    ?? 0
        lastInsertedLevel  = try c.decodeIfPresent(Int.self,   forKey: .lastInsertedLevel) ?? 0
        efSearchMin        = try c.decodeIfPresent(Int.self,   forKey: .efSearchMin)       ?? 50
        efSearchMax        = try c.decodeIfPresent(Int.self,   forKey: .efSearchMax)       ?? 800
        emaExplored        = try c.decodeIfPresent(Float.self, forKey: .emaExplored)       ?? 0
    }

    // MARK: - Compatibility shims

    var isTrained: Bool { entryPoint != -1 }
    var isEmpty:   Bool { entryPoint == -1 }
}

// MARK: - WAL replay

extension HNSWGraph {
    /// Applies one WAL record to reconstruct topology mutations since the last checkpoint.
    ///
    /// All cases are **idempotent**: safe to replay records that are already present in
    /// the loaded checkpoint (e.g. when a crash occurred between checkpoint write and WAL
    /// truncation). `nodeInserted` skips silently if `partitionId` is already in the graph.
    ///
    /// - Important: Call this BEFORE attaching `vectorStore`. The vector file already
    ///   contains the correct data for replayed nodes (it was written during the original
    ///   `hnswInsert`); `apply` only reconstructs the topology side.
    mutating func apply(_ record: TopologyWALRecord) {
        switch record {
        case .nodeInserted(let partitionId, let documentId, let vectorIndex, let level, let neighborsByLayer):
            // Skip if already present (crash-between-checkpoint-and-truncate recovery).
            guard partitionLookup[partitionId] == nil else { break }
            let newIdx = nodes.count
            nodes.append(Node(
                partitionId: partitionId,
                documentId:  documentId,
                vectorIndex: vectorIndex,
                level:       level,
                neighbors:   neighborsByLayer,
                isDeleted:   false
            ))
            partitionLookup[partitionId] = newIdx

        case .neighborsUpdated(let nodeIndex, let layer, let neighbors):
            guard nodeIndex < nodes.count,
                  layer < nodes[nodeIndex].neighbors.count else { break }
            nodes[nodeIndex].neighbors[layer] = neighbors   // idempotent

        case .nodeDeleted(let nodeIndex):
            guard nodeIndex < nodes.count else { break }
            if !nodes[nodeIndex].isDeleted {
                nodes[nodeIndex].isDeleted = true
                partitionLookup.removeValue(forKey: nodes[nodeIndex].partitionId)
            }

        case .entryPointChanged(let nodeIndex, let maxLevel):
            guard nodeIndex == -1 || nodeIndex < nodes.count else { break }  // bounds guard
            entryPoint    = nodeIndex
            self.maxLevel = maxLevel

        case .commit:
            break
        }
    }
}

// MARK: - Mutations

extension HNSWGraph {

    /// Insert a partition into the HNSW graph. Immediate — no buffering.
    /// Must be called before `PartitionIndex.train()` consumes the raw embedding.
    mutating func add(partition: Database.Partition, efOverride: Int? = nil) {
        guard !partition.embedding.isEmpty else { return }
        if let existing = partitionLookup[partition.id] {
            nodes[existing].isDeleted = true
            partitionLookup.removeValue(forKey: partition.id)
            totalDeletions += 1
        }
        hnswInsert(partition: partition, efOverride: efOverride)
        totalInsertions += 1
        // Recalibrate every 64 inserts — sampling 150 nodes per insert is expensive
        // at scale (150 × 1024 float ops each). The threshold converges quickly and
        // doesn't need per-insertion precision once the graph is large.
        guard let store = vectorStore, totalInsertions % 64 == 0 || totalInsertions < 64 else { return }
        store.withReadAccess { accessor in
            updateThreshold(for: partition.embedding, using: accessor)
        }
    }

    /// Mark all nodes for `documentId` as deleted. O(N) worst-case (re-election scan).
    mutating func remove(documentId: DocumentID) {
        var marked = 0
        for idx in nodes.indices where nodes[idx].documentId == documentId {
            nodes[idx].isDeleted = true
            partitionLookup.removeValue(forKey: nodes[idx].partitionId)
            pendingWALRecords.append(.nodeDeleted(nodeIndex: idx))
            marked += 1
        }
        totalDeletions += marked

        if entryPoint != -1 && nodes[entryPoint].isDeleted {
            var newEP = -1
            var newMax = -1
            for (idx, node) in nodes.enumerated() where !node.isDeleted {
                if node.level > newMax {
                    newMax = node.level
                    newEP  = idx
                }
            }
            entryPoint = newEP
            maxLevel   = newMax
            // Always emit — covers both new entry point and empty-graph (-1/-1) cases.
            pendingWALRecords.append(.entryPointChanged(nodeIndex: newEP, maxLevel: newMax))
        }
        pendingWALRecords.append(.commit)
    }

    /// No-op. HNSW inserts incrementally on every `add(partition:)`.
    mutating func trainIfReady() {}

    /// Inserts a partition without the upsert deduplication check in `add(partition:)`.
    /// Use only in tests to simulate phantom nodes that existed before the upsert fix.
    mutating func addWithoutUpsert(_ partition: Database.Partition) {
        guard !partition.embedding.isEmpty else { return }
        hnswInsert(partition: partition)
        if let store = vectorStore {
            store.withReadAccess { accessor in
                updateThreshold(for: partition.embedding, using: accessor)
            }
        }
    }

    /// Update `efSearch` based on the observed exploration depth of the last search.
    mutating func adaptEf(explored: Int) {
        let alpha: Float = 0.15
        emaExplored = emaExplored == 0
            ? Float(explored)
            : (1 - alpha) * emaExplored + alpha * Float(explored)
        let target = Int((emaExplored * 1.5).rounded())
        let prev = efSearch
        efSearch = min(efSearchMax, max(efSearchMin, target))

    }

    // MARK: - Compaction

    /// Compaction result returned by `compact()`.
    struct CompactionResult {
        var removedNodes:       Int
        var removedHubs:        Int
        var demotedEmptyHubs:   Int
        var beforeNodes:        Int
        var afterNodes:         Int
        var afterMaxLevel:      Int
        /// Old `vectorIndex` values in new-node order. Feed to `HNSWVectorStore.rewrite(order:)`
        /// to compact the vector file to match the new topology.
        var survivingVectorIndices: [Int]

        static let zero = CompactionResult(
            removedNodes: 0, removedHubs: 0, demotedEmptyHubs: 0,
            beforeNodes: 0, afterNodes: 0, afterMaxLevel: 0,
            survivingVectorIndices: []
        )
    }

    /// Remove all lazily-deleted nodes and rewire neighbor references.
    ///
    /// Also demotes hub nodes (level > 0) whose upper-layer neighbor lists are all
    /// empty back to level 0.
    ///
    /// Returns a `CompactionResult` which includes `survivingVectorIndices` for the
    /// caller to drive `HNSWVectorStore.rewrite(order:)`. The vector file is NOT touched
    /// here — that is the mutator's responsibility.
    @discardableResult
    mutating func compact() -> CompactionResult {
        let beforeNodes = nodes.count
        let beforeHubs  = nodes.filter { !$0.isDeleted && $0.level > 0 }.count

        // Pre-pass: demote empty hubs.
        var demotedEmptyHubs = 0
        for i in nodes.indices where !nodes[i].isDeleted && nodes[i].level > 0 {
            let upperLayersEmpty = nodes[i].neighbors.dropFirst().allSatisfy { $0.isEmpty }
            if upperLayersEmpty {
                nodes[i].level     = 0
                nodes[i].neighbors = [nodes[i].neighbors[0]]
                demotedEmptyHubs  += 1
            }
        }

        // Build old-index → new-index mapping (-1 = deleted).
        var remap = [Int](repeating: -1, count: nodes.count)
        var newNodes: [Node] = []
        newNodes.reserveCapacity(nodes.count)
        for (old, node) in nodes.enumerated() where !node.isDeleted {
            remap[old] = newNodes.count
            newNodes.append(node)
        }

        // Collect the OLD vectorIndex values in new-node order, BEFORE renumbering.
        // These are the mmap slot positions the vector store must reorder.
        let survivingVectorIndices = newNodes.map { $0.vectorIndex }

        // Rewire neighbor lists using the remap table.
        for i in newNodes.indices {
            newNodes[i].neighbors = newNodes[i].neighbors.map { layer in
                layer.compactMap { old in
                    let new = old < remap.count ? remap[old] : -1
                    return new >= 0 ? new : nil
                }
            }
        }

        // Renumber vectorIndex to sequential 0..n-1 to match the rewritten vector file.
        for i in newNodes.indices { newNodes[i].vectorIndex = i }

        nodes = newNodes

        // Rebuild partitionLookup.
        partitionLookup = [:]
        for (idx, node) in nodes.enumerated() {
            partitionLookup[node.partitionId] = idx
        }

        // Re-elect entry point.
        entryPoint = -1
        maxLevel   = -1
        for (idx, node) in nodes.enumerated() {
            if node.level > maxLevel {
                maxLevel   = node.level
                entryPoint = idx
            }
        }

        let removedNodes = beforeNodes - nodes.count
        let afterHubs    = nodes.filter { $0.level > 0 }.count
        let removedHubs  = beforeHubs - afterHubs - demotedEmptyHubs

        return CompactionResult(
            removedNodes:           removedNodes,
            removedHubs:            removedHubs,
            demotedEmptyHubs:       demotedEmptyHubs,
            beforeNodes:            beforeNodes,
            afterNodes:             nodes.count,
            afterMaxLevel:          maxLevel,
            survivingVectorIndices: survivingVectorIndices
        )
    }

    // MARK: - Diagnostic embedding read

    /// Reads a node's embedding as a `[Float]` array from the mmap'd vector file.
    /// Returns `[]` if the vector store is unavailable (degraded state).
    ///
    /// For use in diagnostic / visualisation paths only. The hot search path uses
    /// `withReadAccess` + `VectorAccessor.vector(at:)` to avoid materialising arrays.
    func readEmbedding(at vectorIndex: Int) -> [Float] {
        guard let store = vectorStore else { return [] }
        return store.withReadAccess { accessor in
            guard accessor.isValid(index: vectorIndex) else { return [] }
            return Array(accessor.vector(at: vectorIndex))
        }
    }

    // MARK: - Graph stats

    var graphStats: (liveNodes: Int, deletedNodes: Int, maxLevel: Int, avgLayer0Degree: Float) {
        var deleted = 0
        var totalDegree = 0
        for node in nodes {
            if node.isDeleted { deleted += 1 }
            totalDegree += node.neighbors.first?.count ?? 0
        }
        let live = nodes.count - deleted
        let avg = nodes.isEmpty ? 0 : Float(totalDegree) / Float(nodes.count)
        return (live, deleted, maxLevel, avg)
    }
}

// MARK: - Search

extension HNSWGraph {
    /// Search for the k nearest partitions to `queryEmbedding`.
    ///
    /// Acquires the vector store read lock for the full cascade duration so that a
    /// concurrent compact rewrite cannot invalidate the mmap pointers mid-search.
    /// Multiple concurrent searches hold the read lock simultaneously.
    ///
    /// Returns `([], emptyTrace)` immediately if `vectorStore` is nil (degraded state).
    struct SearchResult {
        var partitionId: String
        var documentId:  String
        var distance:    Float
    }

    mutating func search(
        queryEmbedding: [Float],
        k: Int,
        nodeFilter: ((String) -> Bool)? = nil
    ) -> (results: [SearchResult], trace: SearchTrace) {
        let emptyTrace = SearchTrace(
            graphNodes: nodes.count, graphMaxLevel: maxLevel,
            upperLayerHops: [], layer0Explored: 0,
            candidatesBeforeFilter: 0, threshold: effectiveThreshold, efUsed: 0
        )
        guard !isEmpty else { return ([], emptyTrace) }
        guard let store = vectorStore  else { return ([], emptyTrace) }

        var ep             = entryPoint
        guard ep < nodes.count else { return ([], emptyTrace) }
        var upperLayerHops = [Int]()
        var layer0Candidates: [HNSWCandidate] = []
        var layer0Explored:   Int = 0

        // Acquire read lock once for the full search. Concurrent searches are fine
        // (rwlock allows multiple readers). Compact rewrites block here until we release.
        store.withReadAccess { accessor in
            // Upper-layer greedy cascade (maxLevel → 1). No predicate here — upper layers
            // must traverse freely to find the best entry point for the base layer.
            for l in stride(from: maxLevel, through: 1, by: -1) {
                let (nearest, hops) = greedyNearest(query: queryEmbedding, from: ep, layer: l, using: accessor)
                ep = nearest
                upperLayerHops.append(hops)
            }

            // Base-layer beam search (layer 0).
            let ef = max(k, efSearch)
            let (candidates, explored) = beamSearch(
                query: queryEmbedding, entryPoints: [ep], layer: 0, ef: ef,
                nodeFilter: nodeFilter, using: accessor
            )
            layer0Candidates = candidates
            layer0Explored   = explored
        }

        // beamSearch already applied the predicate; only remove deleted nodes.
        let liveCandidates = layer0Candidates.filter { !nodes[$0.index].isDeleted }

        let trace = SearchTrace(
            graphNodes:             nodes.count,
            graphMaxLevel:          maxLevel,
            upperLayerHops:         upperLayerHops,
            layer0Explored:         layer0Explored,
            candidatesBeforeFilter: liveCandidates.count,
            threshold:              effectiveThreshold,
            efUsed:                 max(k, efSearch)
        )

        let results = liveCandidates.prefix(k).map { c -> SearchResult in
            let node = nodes[c.index]
            return SearchResult(partitionId: node.partitionId, documentId: node.documentId, distance: c.distance)
        }

        adaptEf(explored: layer0Explored)

        return (Array(results), trace)
    }
}

// MARK: - HNSW core (private)

private extension HNSWGraph {

    // MARK: Insertion

    mutating func hnswInsert(partition: Database.Partition, efOverride: Int? = nil) {
        guard let store = vectorStore else { return }
        let ef       = efOverride ?? efConstruction
        let newLevel = sampleLevel()
        let newIdx   = nodes.count
        let Mmax0    = M * 2

        // Step 1: Write vector to the store BEFORE the node is appended to `nodes`.
        // This ensures any concurrent search that reaches slot `newIdx` finds valid
        // float data even though the node isn't in the topology yet.
        store.append(embedding: partition.embedding)

        // Step 2: Add node to topology (now visible to searches and to the read phase below).
        nodes.append(Node(
            partitionId: partition.id,
            documentId:  partition.documentId,
            vectorIndex: newIdx,
            level:       newLevel,
            neighbors:   [[Int]](repeating: [], count: newLevel + 1)
        ))
        partitionLookup[partition.id] = newIdx
        lastInsertedLevel = newLevel

        // First node becomes the entry point.
        guard entryPoint != -1 else {
            entryPoint = newIdx
            maxLevel   = newLevel
            // WAL: first node — emit node (empty neighbors) and entry point promotion.
            pendingWALRecords.append(.nodeInserted(
                partitionId:      partition.id,
                documentId:       partition.documentId,
                vectorIndex:      newIdx,
                level:            newLevel,
                neighborsByLayer: nodes[newIdx].neighbors
            ))
            pendingWALRecords.append(.entryPointChanged(nodeIndex: newIdx, maxLevel: newLevel))
            return
        }

        var ep = entryPoint
        if ep >= nodes.count {
            var bestEP = -1, bestLevel = -1
            for (idx, node) in nodes.enumerated() where idx != newIdx && !node.isDeleted {
                if node.level > bestLevel { bestLevel = node.level; bestEP = idx }
            }
            entryPoint = bestEP; maxLevel = bestLevel; ep = bestEP
        }

        // Step 3: Greedy descent from maxLevel to newLevel + 1 (read lock).
        if maxLevel > newLevel {
            store.withReadAccess { accessor in
                for l in stride(from: maxLevel, through: newLevel + 1, by: -1) {
                    let (nearest, _) = greedyNearest(query: partition.embedding, from: ep, layer: l, using: accessor)
                    ep = nearest
                }
            }
        }

        // Tracks which (nodeIndex, layer) combos of EXISTING nodes were modified
        // so we emit one `neighborsUpdated` per (node, layer) with the final state.
        var neighborMods: [Int: Set<Int>] = [:]

        // Step 4: Per-layer beam search + bidirectional linking.
        // Each layer acquires its own read lock so that the struct mutations between
        // layers (writing neighbor arrays) don't hold the lock unnecessarily.
        for l in stride(from: min(newLevel, maxLevel), through: 0, by: -1) {
            let Mmax = l == 0 ? Mmax0 : M
            var selected: [HNSWCandidate] = []

            store.withReadAccess { accessor in
                let (candidates, _) = beamSearch(
                    query: partition.embedding, entryPoints: [ep], layer: l,
                    ef: ef, nodeFilter: nil, using: accessor
                )
                // Algorithm 4 heuristic: pick Mmax diverse neighbors from the ef candidates.
                // candidates is sorted nearest-first; c.distance is pivot→c, already computed.
                // The only new work is inter-candidate distances (triangle: M(M-1)/2 per layer).
                var hSelected: [HNSWCandidate] = []
                var hSelectedVecs: [UnsafeBufferPointer<Float>] = []
                hSelected.reserveCapacity(Mmax)
                hSelectedVecs.reserveCapacity(Mmax)
                for c in candidates {
                    guard hSelected.count < Mmax,
                          accessor.isValid(index: nodes[c.index].vectorIndex) else {
                        if hSelected.count >= Mmax { break }
                        continue
                    }
                    let cVec = accessor.vector(at: nodes[c.index].vectorIndex)
                    if !hSelectedVecs.contains(where: { squaredDist(cVec, $0) < c.distance }) {
                        hSelected.append(c)
                        hSelectedVecs.append(cVec)
                    }
                }
                // keepPrunedConnections: backfill if heuristic was overly aggressive.
                if hSelected.count < Mmax {
                    let selectedSet = Set(hSelected.map { $0.index })
                    for c in candidates where !selectedSet.contains(c.index) {
                        if hSelected.count >= Mmax { break }
                        hSelected.append(c)
                    }
                }
                selected = hSelected
            }

            nodes[newIdx].neighbors[l] = selected.map { $0.index }

            // Add reciprocal links; prune any neighbour list that exceeds Mmax.
            for c in selected {
                let cidx = c.index
                guard cidx < nodes.count, l < nodes[cidx].neighbors.count else { continue }
                if !nodes[cidx].neighbors[l].contains(newIdx) {
                    nodes[cidx].neighbors[l].append(newIdx)
                    neighborMods[cidx, default: []].insert(l)
                }
                if nodes[cidx].neighbors[l].count > Mmax {
                    var pruned: [Int] = []
                    store.withReadAccess { accessor in
                        pruned = pruneNeighbors(of: cidx, layer: l, maxCount: Mmax, using: accessor)
                    }
                    nodes[cidx].neighbors[l] = pruned
                    neighborMods[cidx, default: []].insert(l)
                }
            }

            if let nearest = selected.first { ep = nearest.index }
        }

        // Promote global entry point if the new node reaches a higher layer.
        let oldMaxLevel = maxLevel
        if newLevel > maxLevel {
            maxLevel   = newLevel
            entryPoint = newIdx
        }

        // WAL: emit the new node with its final neighbor state (after all backlinks),
        // then one `neighborsUpdated` per modified existing (node, layer), then entry point.
        pendingWALRecords.append(.nodeInserted(
            partitionId:      partition.id,
            documentId:       partition.documentId,
            vectorIndex:      newIdx,
            level:            newLevel,
            neighborsByLayer: nodes[newIdx].neighbors
        ))
        for (cidx, layers) in neighborMods {
            for layer in layers.sorted() {
                guard layer < nodes[cidx].neighbors.count else { continue }
                pendingWALRecords.append(.neighborsUpdated(
                    nodeIndex: cidx,
                    layer:     layer,
                    neighbors: nodes[cidx].neighbors[layer]
                ))
            }
        }
        if newLevel > oldMaxLevel {
            pendingWALRecords.append(.entryPointChanged(nodeIndex: newIdx, maxLevel: newLevel))
        }
        pendingWALRecords.append(.commit)
    }

    // MARK: Graph traversal

    /// Greedy single-hop at `layer`. Returns (nearest node index, hops taken).
    func greedyNearest(
        query: [Float], from start: Int, layer: Int,
        using accessor: VectorAccessor
    ) -> (index: Int, hops: Int) {
        var current     = start
        guard accessor.isValid(index: nodes[current].vectorIndex) else { return (current, 0) }
        var currentDist = squaredDist(query, accessor.vector(at: nodes[current].vectorIndex))
        var hops        = 0

        while true {
            guard layer < nodes[current].neighbors.count else { break }
            var improved = false
            for n in nodes[current].neighbors[layer] {
                guard n < nodes.count,
                      layer < nodes[n].neighbors.count,
                      accessor.isValid(index: nodes[n].vectorIndex) else { continue }
                let d = squaredDist(query, accessor.vector(at: nodes[n].vectorIndex))
                if d < currentDist {
                    current     = n
                    currentDist = d
                    improved    = true
                }
            }
            if !improved { break }
            hops += 1
        }
        return (current, hops)
    }

    /// Beam search on `layer` starting from `entryPoints`.
    ///
    /// When `filter` is non-nil, only nodes whose `documentId` is in the set are added
    /// to `results`. All nodes are still explored via the frontier so graph connectivity
    /// is preserved — unfiltered nodes act as bridges to filtered ones.
    func beamSearch(
        query: [Float],
        entryPoints: [Int],
        layer: Int,
        ef: Int,
        nodeFilter: ((String) -> Bool)?,
        using accessor: VectorAccessor
    ) -> (candidates: [HNSWCandidate], explored: Int) {
        var visited  = Set<Int>()
        var frontier = HNSWMinHeap()
        var results  = [HNSWCandidate]()

        for ep in entryPoints {
            guard ep < nodes.count else { continue }
            let epVI = nodes[ep].vectorIndex
            guard accessor.isValid(index: epVI) else { continue }
            let d = squaredDist(query, accessor.vector(at: epVI))
            let c = HNSWCandidate(index: ep, distance: d)
            frontier.insert(c)
            if nodeFilter == nil || nodeFilter!(nodes[ep].documentId) {
                results.insertSorted(c)
            }
            visited.insert(ep)
        }

        var explored = visited.count

        while !frontier.isEmpty {
            let current     = frontier.removeMin()
            let worstResult = results.last?.distance ?? Float.infinity

            if current.distance > worstResult && results.count >= ef { break }

            guard layer < nodes[current.index].neighbors.count else { continue }

            for n in nodes[current.index].neighbors[layer] {
                guard n < nodes.count,
                      layer < nodes[n].neighbors.count,
                      !visited.contains(n) else { continue }
                let nVI = nodes[n].vectorIndex
                guard accessor.isValid(index: nVI) else { continue }
                visited.insert(n)
                explored += 1

                let d     = squaredDist(query, accessor.vector(at: nVI))
                let worst = results.last?.distance ?? Float.infinity

                // Always add to frontier if it could help reach closer filtered nodes.
                if d < worst || results.count < ef {
                    frontier.insert(HNSWCandidate(index: n, distance: d))
                }

                // Only add to results if the node is live and passes the predicate.
                // Deleted nodes are still traversed (frontier) to preserve graph connectivity,
                // but are never returned as candidates — prevents repair from wiring live nodes
                // to dead neighbours, and ensures search never returns stale results.
                if !nodes[n].isDeleted,
                   nodeFilter == nil || nodeFilter!(nodes[n].documentId) {
                    if d < worst || results.count < ef {
                        let c = HNSWCandidate(index: n, distance: d)
                        results.insertSorted(c)
                        if results.count > ef { results.removeLast() }
                    }
                }
            }
        }

        return (results, explored)
    }

    // MARK: Neighbour pruning

    /// Prune the neighbour list for node `idx` at `layer` to `maxCount` entries,
    /// retaining the geometrically closest ones to the pivot node.
    func pruneNeighbors(
        of idx: Int, layer: Int, maxCount: Int,
        using accessor: VectorAccessor
    ) -> [Int] {
        guard idx < nodes.count,
              layer < nodes[idx].neighbors.count,
              accessor.isValid(index: nodes[idx].vectorIndex) else { return [] }
        let pivotVec = accessor.vector(at: nodes[idx].vectorIndex)
        // Precompute all distances once — the sort comparator would otherwise recompute
        // each distance on every comparison (O(N log N) redundant calls).
        return nodes[idx].neighbors[layer]
            .compactMap { c -> (Int, Float)? in
                guard c < nodes.count, accessor.isValid(index: nodes[c].vectorIndex) else { return nil }
                return (c, squaredDist(pivotVec, accessor.vector(at: nodes[c].vectorIndex)))
            }
            .sorted { $0.1 < $1.1 }
            .prefix(maxCount)
            .map { $0.0 }
    }

    // MARK: Level sampling

    func sampleLevel() -> Int {
        let mL  = 1.0 / log(Double(max(M, 2)))
        let u   = Double.random(in: Double.leastNormalMagnitude..<1)
        let raw = Int(-log(u) * mL)
        let cap = max(1, Int(log(Double(max(nodes.count, 2))) / log(Double(max(M, 2)))) + 2)
        return min(raw, cap)
    }

    // MARK: Distance

    /// Squared Euclidean distance between a `[Float]` query and a mmap'd node vector.
    /// Delegates to the shared MLXAccelerate CPU kernel (8-accumulator SIMD).
    @inline(__always)
    func squaredDist(_ a: [Float], _ b: UnsafeBufferPointer<Float>) -> Float {
        let n = Swift.min(a.count, b.count)
        return a.withUnsafeBufferPointer { ap in
            squaredEuclidean(ap.baseAddress!, b.baseAddress!, n)
        }
    }

    /// Squared Euclidean distance between two mmap'd node vectors (used in `pruneNeighbors`).
    @inline(__always)
    func squaredDist(_ a: UnsafeBufferPointer<Float>, _ b: UnsafeBufferPointer<Float>) -> Float {
        squaredEuclidean(a.baseAddress!, b.baseAddress!, Swift.min(a.count, b.count))
    }

    // MARK: Threshold calibration

    /// Incrementally update `effectiveThreshold` from the inserted embedding.
    /// Called once per `add(partition:)`, under its own read lock.
    mutating func updateThreshold(for embedding: [Float], using accessor: VectorAccessor) {
        guard nodes.count > 10 else { return }

        let sampleSize = min(150, nodes.count - 1)
        let step       = max(1, (nodes.count - 1) / sampleSize)
        var dists      = [Float]()
        dists.reserveCapacity(sampleSize)

        var i = 0
        while i < nodes.count - 1 && dists.count < sampleSize {
            if !nodes[i].isDeleted && accessor.isValid(index: nodes[i].vectorIndex) {
                dists.append(squaredDist(embedding, accessor.vector(at: nodes[i].vectorIndex)))
            }
            i += step
        }

        guard !dists.isEmpty else { return }
        let mean     = dists.reduce(0, +) / Float(dists.count)
        let variance = dists.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(dists.count)
        let proposed = mean + 1.5 * sqrt(variance)

        if effectiveThreshold.isInfinite || nodes.count < 100 {
            effectiveThreshold = proposed
        } else {
            effectiveThreshold = 0.9 * effectiveThreshold + 0.1 * proposed
        }
    }
}

