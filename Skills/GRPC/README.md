# GRPC

Totem's gRPC layer has two responsibilities: exposing search and index services directly (reachable by any gRPC client on `--grpc-port`), and maintaining a persistent bidirectional session stream with Seer so traffic can flow through the mothership.

---

## Services

### TotemQuery

Handles search, indexing, and document removal.

| RPC | Description |
|---|---|
| `Search` | Hybrid KG + PQ search. Accepts `query_text` (Totem embeds) or `query_embedding` (precomputed); optional `entities` for graph matching. Response carries a graph trace. |
| `Index` | Embed and index a batch of documents. Returns immediately; background write queue drains async. |
| `Remove` | Remove specific document IDs, or all documents for an owner when `document_ids` is empty. |

Implementation: [TotemQueryServiceImpl.swift](../../Sources/GRPC/TotemQueryServiceImpl.swift)

### TotemLibrary

Paginated document library.

| RPC | Description |
|---|---|
| `Library` | Paginated list of groups for an owner. `after_id` is a cursor; `limit` controls page size. |

Implementation: [TotemLibraryServiceImpl.swift](../../Sources/GRPC/TotemLibraryServiceImpl.swift)

### TotemGraph

Knowledge-graph queries.

| RPC | Description |
|---|---|
| `Query` | Resolve seed entities by name and/or free-text similarity (Totem embeds `query`), traverse up to `hops` edges (0–3), return entities, relationships, linked documents, and graph stats. |

Implementation: [TotemGraphServiceImpl.swift](../../Sources/Conduit/TotemGraphServiceImpl.swift)

---

## Seer Session — How It Works

When `--mothership-host` is provided, `MothershipRegistrationClient` starts and runs for the process lifetime.

### Phase 1 — Register

`register` RPC: Totem sends its UUID, HTTP host, gRPC port, and HTTP port. Seer records the node and returns an acceptance signal. Totem retries every 5 s until accepted.

### Phase 2 — Session stream

`session` RPC: Totem opens a bidirectional stream and holds it open. Traffic flows in both directions over this single connection:

- **Totem → Seer**: periodic pings every 30 s to keep the stream alive.
- **Seer → Totem**: request payloads (search, index, remove, library, graph, update, stats) wrapped in `TotemSessionMessage`.

`MothershipRequestDispatcher` reads the `payload` oneof from each incoming message, calls the matching service impl, and writes the response back with the same `correlationID`.

### Phase 3 — Availability updates

`updateAvailability` RPC: one-shot call Totem makes when its storage capacity changes (e.g. after a large batch completes). Seer uses this to steer new index requests toward nodes that are accepting storage.

### Reconnection

If the session stream drops, `MothershipRegistrationClient` sleeps 5 s and restarts the registration loop from Phase 1.

---

## Session Message Envelope

Every payload over the `session` stream is wrapped in `TotemSessionMessage`:

```protobuf
message TotemSessionMessage {
  string correlation_id = 1;   // ties each request to its response
  string totem_id       = 2;   // set by Totem so Seer can route back to the right stream

  oneof payload {
    TotemSessionPing            ping                      = 3;
    TotemSessionPong            pong                      = 4;
    TotemSearchRequest          search_request            = 5;
    TotemSearchResponse         search_response           = 6;
    TotemIndexRequest           index_request             = 7;
    TotemIndexResponse          index_response            = 8;
    TotemRemoveRequest          remove_request            = 9;
    TotemRemoveResponse         remove_response           = 10;
    TotemLibraryRequest         library_request           = 11;
    TotemLibraryResponse        library_response          = 12;
    // 13–22 reserved (retired TotemHNSW arms)
    TotemUpdateGroupRequest     update_group_request      = 23;
    TotemUpdateGroupResponse    update_group_response     = 24;
    TotemUpdateDocumentRequest  update_document_request   = 25;
    TotemUpdateDocumentResponse update_document_response  = 26;
    TotemStatsRequest           stats_request             = 27;
    TotemStatsResponse          stats_response            = 28;
    TotemGraphQueryRequest      graph_request             = 29;
    TotemGraphQueryResponse     graph_response            = 30;
  }
}
```

---

## Adding a New RPC

1. Add the message and RPC definition to `Conduit/Protos/totem.proto` (shared package).
2. Regenerate Swift stubs (`Conduit/scripts/generate.sh`).
3. Add a `case` to the `payload` oneof in `MothershipRequestDispatcher` that calls the appropriate service impl.
4. Implement the handler in the relevant `ServiceImpl` file.

---

## Key Files

| File | Purpose |
|---|---|
| [totem.proto](../../Sources/GRPC/totem.proto) | Proto definitions for all messages and services |
| [MothershipRegistrationClient.swift](../../Sources/GRPC/MothershipRegistrationClient.swift) | Register, session loop, reconnection |
| [MothershipRequestDispatcher.swift](../../Sources/GRPC/MothershipRequestDispatcher.swift) | Route session messages to service impls |
| [TotemGRPCServer.swift](../../Sources/GRPC/TotemGRPCServer.swift) | gRPC server startup and service registration |
| [TotemQueryServiceImpl.swift](../../Sources/GRPC/TotemQueryServiceImpl.swift) | Search / Index / Remove |
| [TotemLibraryServiceImpl.swift](../../Sources/GRPC/TotemLibraryServiceImpl.swift) | Library pagination |
| [TotemHNSWServiceImpl.swift](../../Sources/GRPC/TotemHNSWServiceImpl.swift) | Graph stats and node ops |
