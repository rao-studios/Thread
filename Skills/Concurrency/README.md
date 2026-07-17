# Concurrency

Totem uses Swift actors throughout. All mutable state lives inside the `Database` actor. Writes to the partition table and registry are further serialized through dedicated mutators.

---

## Database Actor

`Database` is the root actor. It:

- Owns `TotemRegistry`, `PartitionTable`, and the `GraphStore`.
- Serializes all reads and writes through its executor.
- Restores plist snapshots and runs reconciliation sweeps on startup before serving any requests.
- Exposes async methods used by gRPC service impls and HTTP route handlers.

---

## RegistryMutator

`RegistryMutator` serializes all writes to `TotemRegistry`.

Every registry mutation (register, linkOwner, updateAccess) goes through this mutator. Hot-path mutations schedule a debounced snapshot; cold-path mutations persist immediately.

File: [RegistryMutator.swift](../../Sources/Database/Mutators/RegistryMutator.swift)

---

## TableMutator

`TableMutator` serializes all writes to `PartitionTable` and `GraphStore` — the two stores mutate as one logical unit.

Every partition index update and graph upsert/detach goes through this mutator, then flushes on a shared 1-second debounce.

File: [TableMutator.swift](../../Sources/Database/Mutators/TableMutator.swift)

---

## Caching — ReadWriteValue and LockedValue

`ReadWriteValue<T>` — reader/writer lock for values that are read-heavy and written rarely (e.g. cached search results, group metadata). Multiple readers can proceed concurrently; a write excludes all readers.

`LockedValue<T>` — simple mutex wrapper for values that need mutual exclusion without reader/writer distinction.

Both are defined in [Utilities/Database/](../../Sources/Utilities/Database/).

---

## TotemCache / DocumentCache

`TotemCache` — an LRU-evicting in-memory cache for recently accessed search results and intermediate data.

`DocumentCache` — per-document cache layer that sits in front of `PartitionIndex` reads. Avoids redundant disk access for hot documents.

Files: [TotemCache.swift](../../Sources/Utilities/Database/TotemCache.swift), [DocumentCache.swift](../../Sources/Utilities/Database/DocumentCache.swift)

---

## Indexing — Background Task Pattern

`Database+Put.index(request:)` returns immediately to the caller after validating the request and submitting a detached background task. The background task embeds text, updates the registry, and drains writes through `TableMutator`. This keeps the gRPC call latency low even for large batches.

---

## Rules

- Never mutate `PartitionTable` or `TotemRegistry` directly — always go through the matching mutator.
- Never bypass the mutators. Direct cache writes race with the debounced saves and can be lost on restart.
- Use `ReadWriteValue` for cache-like state; use `LockedValue` for small critical sections; use actor isolation for everything owned by `Database`.
