# Totem Skills

Maintenance, reference, and operational knowledge for every system in Totem. Use these when building new features, auditing existing behavior, writing tests, or debugging distributed search.

---

## Directory Structure

```
Skills/
├── Database/             — Vector database internals
│   └── README.md         — PartitionTable, GraphStore (KG), PQ compression, Registry
│
├── GRPC/                 — gRPC services and Seer session
│   └── README.md         — Service impls, session stream, mothership registration, dispatcher
│
├── Providers/            — Embedding model backends
│   └── README.md         — Mistral API provider, MLX on-device provider, priority queue
│
├── Concurrency/          — Actor design and write serialization
│   └── README.md         — Database actor, RegistryMutator, TableMutator, IndexQueue
│
├── Persistence/          — Plist snapshots and reconciliation
│   └── README.md         — Debounced saves, startup sweeps, file layout
│
└── API/                  — HTTP routes (standalone mode)
    └── README.md         — BatchEmbeddings, Search, Graph, Library routes, request shapes
```

---

## Quick Lookup

| I want to... | Go to |
|---|---|
| Understand how Totem connects to Seer | [GRPC/README.md](GRPC/README.md) |
| Add or modify a gRPC service | [GRPC/README.md](GRPC/README.md) |
| Understand the knowledge graph and PQ compression | [Database/README.md](Database/README.md) |
| Change how documents are indexed or searched | [Database/README.md](Database/README.md) |
| Add a new embedding backend | [Providers/README.md](Providers/README.md) |
| Understand actor design and write serialization | [Concurrency/README.md](Concurrency/README.md) |
| Understand snapshot persistence and reconciliation | [Persistence/README.md](Persistence/README.md) |
| Add or modify an HTTP route | [API/README.md](API/README.md) |

---

## System Map

| System | What it does |
|---|---|
| **Database** | Core actor: owns all search state, routes indexed writes, dispatches searches |
| **PartitionTable** | Flat per-document PQ index map: parallel ADC scan, entity pre-filter, graph expansion |
| **GraphStore** | Knowledge graph: content-addressed entities, weighted relationships, BFS traversal |
| **PQ (PartitionQuantizer)** | Product quantization: compresses 1024-float vectors to compact UInt16 codes |
| **Registry** | Ownership layer: document-to-owner mapping, deduplication, access control |
| **GRPC** | Session stream: registers with Seer, dispatches bidirectional session messages |
| **Providers** | Embedding backends: Mistral API (priority queue) or on-device MLX |
| **Concurrency** | Mutators: serialized write paths for the registry and partition table |
| **Persistence** | Plist snapshots: debounced full-file saves, startup reconciliation sweeps |
| **API** | HTTP routes: standalone index/search/graph/library endpoints |
