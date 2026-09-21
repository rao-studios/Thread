# Persistence

Thread persists all state as binary property-list snapshots under its data directory (`~/Documents/thread-db` by default; see Data Directory). There is no WAL and no memory-mapped store — durability is debounced full-file saves with startup reconciliation sweeps.

---

## Files (per node UUID)

| File | Contents |
|---|---|
| `table-<nodeId>` | `PartitionTable` — PQ codebooks, lean slots, entity linkage |
| `graph-<nodeId>` | `GraphStore` — entities + relationships (adjacency rebuilt on decode) |
| `registry` | `ThreadRegistry` — ownership, groups, access, stats |
| `documents/{id}` | `Database.Document` |
| `documents/{id}-parts` | `[PartitionData]` — partition text/url/owner, loaded on demand; plus the caller-supplied embedding (fp32, little-endian) for partitions indexed with one, which the PQ table cannot reproduce |
| `node-id` | Persisted node UUID |

---

## Durability Model

- **Hot path (put)** — `TableMutator` and `RegistryMutator` update in-memory caches immediately and schedule a **1-second debounced** full-file save. The table and graph share one debounce so they flush together.
- **Cold path (remove, access update, group rename, shutdown)** — saved immediately (`saveNow`).
- All disk I/O routes through a per-cache `PersistenceActor` so concurrent saves never race on the same file.

---

## Startup Reconciliation

`Database.initializeTable()` closes the small crash window the debounce leaves open:

1. `purgeLegacyShardFiles()` — removes artifacts from the previous HNSW/WAL/shard format (`shard-<nodeId>*`, `registry-wal`).
2. Restore `table-<nodeId>` and `graph-<nodeId>`.
3. **Sweep 1** — table documents absent from the registry are removed from the table and detached from the graph.
4. **Sweep 2** — registry documents with no table index (crash inside the debounce window) are dropped from the registry and their files purged, so re-ingest is not skipped by the dedup check.

---

## Data Directory

Snapshot files, the knowledge graph, documents and `node-id` all live under one root, `FilePersistence.getDefaultURL()`: `~/Documents/thread-db` by default, or whatever `thread --data-dir <path>` / the `THREAD_DATA_DIR` environment variable names (the flag wins; tilde is expanded and the directory is created on startup). Mary launches Thread with `--data-dir ~/Documents/maryOS/thread-db`. Do not delete or move these files while the server is running.

---

## Key Files

| File | Purpose |
|---|---|
| [FilePersistence.swift](../../Sources/Utilities/Persistence/FilePersistence.swift) | Plist encode/decode, atomic writes, purge |
| [PersistenceActor.swift](../../Sources/Utilities/Persistence/PersistenceActor.swift) | Actor wrapper for file I/O serialization |
| [ThreadCache.swift](../../Sources/Utilities/Database/ThreadCache.swift) | Lock-protected snapshot + serialized saves |
| [NodeIdentity.swift](../../Sources/Utilities/Persistence/NodeIdentity.swift) | Stable per-process node UUID (used in Sewn registration) |
