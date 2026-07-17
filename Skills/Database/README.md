# Database

The `Database` actor is Totem's storage and search core. It owns every piece of mutable state: the partition table, the knowledge graph, and the registry. All reads and writes are serialized through this actor.

---

## Component Map

```
Database (actor)
├── RegistryMutator        — serialized writes to TotemRegistry
│   └── TotemRegistry      — ownership, deduplication, access control
├── TableMutator           — serialized writes to PartitionTable + GraphStore
│   ├── PartitionTable     — per-document PQ search index
│   │   └── PartitionIndex × M — one per document
│   │       └── PartitionQuantizer — PQ codebooks + ADC
│   └── GraphStore         — knowledge graph (entities + relationships)
└── DocumentCache          — in-memory Document lookups
```

The `PartitionTable` and `GraphStore` mutate together on every put/remove (a document's partitions and the entities it contributes are one logical unit), so a single actor owns both.

---

## Registry

`TotemRegistry` is the ownership and access-control layer. Every document must be registered before it can be indexed or searched.

| Concept | Description |
|---|---|
| `ownerId` | Arbitrary string identifying the caller — passed in the request, no auth |
| `DocumentID` | SHA-256 hash of the document's text chunks — content-addressed |
| `GroupID` | Owner-defined namespace bundling documents together |
| `Access` | `.available` (globally searchable) or `.restricted` (owner-only, default) |

**Deduplication**: if two owners submit identical text, only one copy of the vectors is stored. The second owner is linked to the existing document via `linkOwner`.

### Registry mutations

- `register(document:owner:group:)` — create entry, assign to owner
- `linkOwner(_:document:)` — attach a second owner to an existing document
- `updateAccess(_:document:owner:)` — change `.restricted` ↔ `.available`

Durability is a 1-second debounced full-file snapshot; cold-path mutations (remove, access update, group rename) persist immediately.

---

## PartitionTable

`PartitionTable` is a flat map `[DocumentID: PartitionIndex]`. Vector search is a parallel per-document ADC scan — there is no HNSW graph, no sharding, and no WAL.

### PartitionIndex

Holds everything for one document:

- Lean slots (PQ codes + IDs — text lives on disk in `documents/{id}-parts`)
- Learned codebooks (trained from the document's own partitions)
- `entityIds` — graph entities this document contributes provenance to
- `entityEmbedding` — exact embedding of the joined entity names (entity pre-filter)
- Optional metadata blob

---

## GraphStore (Knowledge Graph)

`GraphStore` is a Spanner-Graph-style projection over the corpus: entities and relationships are plain records with inverted document-provenance indexes, persisted as one plist alongside the table.

- **Entity** — content-addressed by `(kind, normalized name)`, so the same concept across documents merges into one node. Carries a raw embedding of `"kind: name"` and a `documentIds` provenance set.
- **Relationship** — directed typed edge `subject —predicate→ object`; `weight` increments each time the same triple is observed.
- **Adjacency** — derived index, rebuilt on decode (never persisted, never stale).

Key operations: `upsert(payload, documentId)` (merge a document's extracted graph), `detach` (remove provenance + garbage-collect empty nodes/edges), `matchEntities` (name-token containment or cosine ≥ 0.15), `neighborhood(seeds, hops)` (BFS), `documents(linkedTo:)`.

Entity/relationship extraction happens at ingest: caller-provided payloads, keyword fallback (`TagGenerator`), or on-device LLM extraction (`MLXGraphExtractionProvider`, Qwen3-1.7B-4bit) in a detached post-response task — see `GraphEnrichment`.

---

## Product Quantization (PQ)

`PartitionQuantizer` compresses 1024-float embeddings into compact `UInt16` code sequences.

- The embedding is split into `subvectorCount` equal chunks.
- Each chunk is encoded against an independent k-means codebook trained on the document's own partitions.
- Codebook size scales with training corpus: small documents use k=2; large shared indices may reach k=2048.
- Search uses **Asymmetric Distance Computation (ADC)**: pre-compute distance tables from the query to all centroids, then scan compressed codes in tight loops — no full vector loads needed.
- `adaptiveThreshold` is calibrated per-document from reconstruction errors and overrides the static per-codec fallback at search time.
- Training runs on GPU via `MLXAccelerate.kmeans` when enabled (`TOTEM_PQ_MLX`), CPU k-means++ otherwise.

---

## Search Flow (hybrid KG + vector)

1. `Database+Search.search(request:)` receives a query text or precomputed embedding. If text: embed via `EmbeddingModelProvider`.
2. Match query entities against the graph (name tokens + content-vector cosine) → `matchedEntityIds`.
3. Candidate documents from scope (owner / group / global).
4. **Entity pre-filter**: documents linked to a matched entity — or whose entity embedding is close to the query's entity embedding — pass; documents with no entities always pass.
5. **Parallel ADC scan** over the candidates (`concurrentPerform`), k per document.
6. **One-hop graph expansion**: documents linked to neighbors of the result/query entities are pulled in, ranked by summed edge weight, scored with a ×1.1 penalty so a graph-reached hit never outranks an equally-close direct hit.
7. Return partitions + scores + `GraphSearchTrace` (matched entities, expansion edges, expanded doc count).

---

## Index Flow

1. `Database+Put.putBatch(request:)` receives text chunks, a `GraphPayload`, and owner metadata (embedding + provisional entity resolution already ran in the route/gRPC layer).
2. Parts files (`documents/{id}-parts`) are pre-written in a bounded parallel task group.
3. Register document with `TotemRegistry` (or link existing if deduplicated).
4. `TableMutator.putBatch`: `graphStore.upsert(...)` resolves entity IDs → `table.put(...)` trains a fresh `PartitionIndex`.
5. Both stores flush on a shared 1-second debounce; removes and shutdown save immediately.

---

## Key Files

| File | Purpose |
|---|---|
| [Database.swift](../../Sources/Database/Database.swift) | Actor declaration, startup, write queue |
| [Database+Index.swift](../../Sources/Database/Database+Index.swift) | Index orchestration + startup reconciliation |
| [Database+Search.swift](../../Sources/Database/Commands/Database+Search.swift) | Hybrid search entry |
| [Database+Graph.swift](../../Sources/Database/Commands/Database+Graph.swift) | Graph query (matchEntities + neighborhood) |
| [Database+Registry.swift](../../Sources/Database/Database+Registry.swift) | Registry delegation |
| [PartitionTable.swift](../../Sources/Database/PartitionTable/PartitionTable.swift) | Flat table + hybrid search + expansion |
| [PartitionIndex.swift](../../Sources/Database/PartitionTable/PartitionIndex.swift) | Per-document index |
| [PartitionQuantizer.swift](../../Sources/Database/PartitionTable/PartitionQuantizer.swift) | PQ codebooks and ADC |
| [GraphStore.swift](../../Sources/Database/Graph/GraphStore.swift) | Knowledge graph: entities, relationships, traversal |
| [GraphEnrichment.swift](../../Sources/Providers/GraphEnrichment.swift) | Detached LLM extraction + entity embedding |
