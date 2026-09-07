# GRPC

Thread's gRPC layer has two responsibilities: exposing search and index services directly (reachable by any gRPC client on `--grpc-port`), and maintaining a persistent bidirectional session stream with Sewn so traffic can flow through the mothership.

---

## Services

### ThreadQuery

Handles search, indexing, and document removal.

| RPC | Description |
|---|---|
| `Search` | Hybrid KG + PQ search. Accepts `query_text` (Thread embeds) or `query_embedding` (precomputed); optional `entities` for graph matching. Response carries a graph trace. |
| `Index` | Embed and index a batch of documents. Returns immediately; background write queue drains async. |
| `Remove` | Remove specific document IDs, or all documents for an owner when `document_ids` is empty. |

Implementation: [ThreadQueryServiceImpl.swift](../../Sources/GRPC/ThreadQueryServiceImpl.swift)

### ThreadLibrary

Paginated document library.

| RPC | Description |
|---|---|
| `Library` | Paginated list of groups for an owner. `after_id` is a cursor; `limit` controls page size. |

Implementation: [ThreadLibraryServiceImpl.swift](../../Sources/GRPC/ThreadLibraryServiceImpl.swift)

### ThreadGraph

Knowledge-graph queries.

| RPC | Description |
|---|---|
| `Query` | Resolve seed entities by name and/or free-text similarity (Thread embeds `query`), traverse up to `hops` edges (0–3), return entities, relationships, linked documents, and graph stats. |

Implementation: [ThreadGraphServiceImpl.swift](../../Sources/Conduit/ThreadGraphServiceImpl.swift)

---

## Sewn Session — How It Works

When `--mothership-host` is provided, `MothershipRegistrationClient` starts and runs for the process lifetime.

### Phase 1 — Register

`register` RPC: Thread sends its UUID, HTTP host, gRPC port, and HTTP port. Sewn records the node and returns an acceptance signal. Thread retries every 5 s until accepted.

### Phase 2 — Session stream

`session` RPC: Thread opens a bidirectional stream and holds it open. Traffic flows in both directions over this single connection:

- **Thread → Sewn**: periodic pings every 30 s to keep the stream alive.
- **Sewn → Thread**: request payloads (search, index, remove, library, graph, update, stats) wrapped in `ThreadSessionMessage`.

`MothershipRequestDispatcher` reads the `payload` oneof from each incoming message, calls the matching service impl, and writes the response back with the same `correlationID`.

### Phase 3 — Availability updates

`updateAvailability` RPC: one-shot call Thread makes when its storage capacity changes (e.g. after a large batch completes). Sewn uses this to steer new index requests toward nodes that are accepting storage.

### Reconnection

If the session stream drops, `MothershipRegistrationClient` sleeps 5 s and restarts the registration loop from Phase 1.

---

## Session Message Envelope

Every payload over the `session` stream is wrapped in `ThreadSessionMessage`:

```protobuf
message ThreadSessionMessage {
  string correlation_id = 1;   // ties each request to its response
  string thread_id       = 2;   // set by Thread so Sewn can route back to the right stream

  oneof payload {
    ThreadSessionPing            ping                      = 3;
    ThreadSessionPong            pong                      = 4;
    ThreadSearchRequest          search_request            = 5;
    ThreadSearchResponse         search_response           = 6;
    ThreadIndexRequest           index_request             = 7;
    ThreadIndexResponse          index_response            = 8;
    ThreadRemoveRequest          remove_request            = 9;
    ThreadRemoveResponse         remove_response           = 10;
    ThreadLibraryRequest         library_request           = 11;
    ThreadLibraryResponse        library_response          = 12;
    // 13–22 reserved (retired ThreadHNSW arms)
    ThreadUpdateGroupRequest     update_group_request      = 23;
    ThreadUpdateGroupResponse    update_group_response     = 24;
    ThreadUpdateDocumentRequest  update_document_request   = 25;
    ThreadUpdateDocumentResponse update_document_response  = 26;
    ThreadStatsRequest           stats_request             = 27;
    ThreadStatsResponse          stats_response            = 28;
    ThreadGraphQueryRequest      graph_request             = 29;
    ThreadGraphQueryResponse     graph_response            = 30;
  }
}
```

---

## Adding a New RPC

1. Add the message and RPC definition to `Conduit/Protos/thread.proto` (shared package).
2. Regenerate Swift stubs (`Conduit/scripts/generate.sh`).
3. Add a `case` to the `payload` oneof in `MothershipRequestDispatcher` that calls the appropriate service impl.
4. Implement the handler in the relevant `ServiceImpl` file.

---

## Key Files

| File | Purpose |
|---|---|
| [thread.proto](../../Sources/GRPC/thread.proto) | Proto definitions for all messages and services |
| [MothershipRegistrationClient.swift](../../Sources/GRPC/MothershipRegistrationClient.swift) | Register, session loop, reconnection |
| [MothershipRequestDispatcher.swift](../../Sources/GRPC/MothershipRequestDispatcher.swift) | Route session messages to service impls |
| [ThreadGRPCServer.swift](../../Sources/GRPC/ThreadGRPCServer.swift) | gRPC server startup and service registration |
| [ThreadQueryServiceImpl.swift](../../Sources/GRPC/ThreadQueryServiceImpl.swift) | Search / Index / Remove |
| [ThreadLibraryServiceImpl.swift](../../Sources/GRPC/ThreadLibraryServiceImpl.swift) | Library pagination |
| [ThreadHNSWServiceImpl.swift](../../Sources/GRPC/ThreadHNSWServiceImpl.swift) | Graph stats and node ops |
