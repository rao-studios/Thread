//
//  QueryEmbeddingCache.swift
//  database-server
//
//  Bounded cache for SEARCH query embeddings. The embedding model is fixed
//  per process (mistral-embed, chosen once at startup), so text → vector is a
//  stable pure function — and every hit removes a ~500ms Mistral round-trip
//  from the chat critical path.
//
//  Deliberately scoped to the search call sites, NOT EmbeddingModelProvider:
//  bulk-index texts almost never repeat and would evict the queries that do.
//
//  Follows DocumentCache's lock discipline (ReadWriteValue, no actor hop),
//  plus simple insertion-order eviction — repeated chat turns dominate reuse,
//  so full LRU recency isn't worth the bookkeeping.
//

import Foundation

final class QueryEmbeddingCache: Sendable {
    private struct Store {
        var vectors: [String: [Float]] = [:]
        var insertionOrder: [String] = []
    }

    private let _store: ReadWriteValue<Store>
    private let capacity: Int

    init(capacity: Int = 256) {
        self._store = ReadWriteValue(Store())
        self.capacity = capacity
    }

    func get(_ text: String) -> [Float]? {
        _store.withReadLock { $0.vectors[text] }
    }

    func cache(_ text: String, vector: [Float]) {
        guard !vector.isEmpty else { return }
        _store.withWriteLock { store in
            if store.vectors[text] == nil {
                store.insertionOrder.append(text)
            }
            store.vectors[text] = vector
            while store.insertionOrder.count > capacity {
                let evicted = store.insertionOrder.removeFirst()
                store.vectors.removeValue(forKey: evicted)
            }
        }
    }
}
