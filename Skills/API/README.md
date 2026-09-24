# API

Thread's HTTP layer is the **standalone path**. In distributed mode, all production traffic flows through the gRPC session stream with Sewn. The HTTP routes remain available for direct use and debugging in both modes.

---

## Routes

> **The request wrapper key is `thread`.** It was `sewn` in earlier revisions,
> and a stale spelling decodes as `400 Coding key \`thread\` not found.` rather
> than as a missing field — so a client on the old name fails every scoped call.

### `POST /health`

Returns `{"status":"ok"}`. No auth required. Used by load balancers and Sewn to verify liveness.

File: [Health.swift](../../Sources/API/Routes/Health.swift)

---

### `GET /v1/availability`

Returns current storage availability state. Sewn uses this to decide whether to route new index requests to this node.

File: [Availability.swift](../../Sources/API/Routes/Availability.swift)

---

### `POST /v1/batch/embeddings`

Indexes one or more documents. Each document's text is embedded and PQ-compressed, and its entities/relationships are merged into the knowledge graph (LLM extraction runs in the detached enrichment pass when the caller supplies none). Returns immediately — enrichment + indexing happen in a detached background task.

**Request**

```json
{
  "inputs": ["A string, or...", ["array", "of", "strings"]],
  "sanitize": true,
  "thread": {
    "owner_id": "alice",
    "group": {
      "id": "my-group",
      "label": "My Knowledge Base",
      "owner_id": "alice",
      "documents": []
    }
  },
  "tags": [["optional", "per-document", "tags"]],
  "media_type": "text"
}
```

| Field | Required | Description |
|---|---|---|
| `inputs` | Yes | One entry per document. String or array of strings. |
| `thread.owner_id` | Yes | Identity of the caller. Lowercased on receipt. |
| `thread.group` | No | Assigns all documents in this batch to a named group. |
| `sanitize` | No | When `true`, passes each input through `TextChunker`. Default: `false`. |
| `tags` | No | Per-document tag hints. Outer index aligns 1:1 with `inputs`. Auto-generated if empty. |
| `media_type` | No | `"text"` (default), `"image"` or `"code"`. |

File: [BatchEmbeddings.swift](../../Sources/API/Routes/BatchEmbeddings.swift)

---

### `POST /v1/search`

Searches indexed documents for the closest matching partitions to a query string.

**Request**

```json
{
  "query": "how does product quantization work?",
  "thread": {
    "owner_id": "alice",
    "scope": "personal",
    "aggregate": false
  }
}
```

| Field | Required | Description |
|---|---|---|
| `query` | Yes | Natural language query. Embedded at search time. |
| `thread.owner_id` | Yes | Scopes the search to this owner's documents. |
| `thread.scope` | No | `personal` (default) or `global` (all `.available` documents). |
| `thread.aggregate` | No | Searches all of the owner's documents and ignores `group`/`groups`. |
| `thread.group` / `thread.groups` | No | Restrict search to specific groups. |
| `thread.entities` | No | Graph match terms (`thread.tags` is a legacy alias). |
| `thread.media_type` | No | `code` (identifier boost, code partitions only) or `text` (text partitions only). |
| `thread.top_k` | No | The most partitions to return, across documents. |

**Response**

```json
{
  "object": "list",
  "texts": ["...most relevant partition text..."],
  "references": [
    { "document_id": "abc123", "partition_id": "def456", "distance": 0.12 }
  ]
}
```

File: [Search.swift](../../Sources/API/Routes/Search.swift)

---

### `POST /v1/library`

Paginated list of groups for an owner.

File: [Library.swift](../../Sources/API/Routes/Library.swift)

---

### `POST /v1/graph`

Knowledge-graph query: resolve entities by name (`entity`) and/or free-text similarity (`query`, embedded server-side), traverse up to `hops` edges (0–3), and return entities, relationships, linked documents, and graph stats. At least one of `entity` / `query` is required.

File: [Graph.swift](../../Sources/API/Routes/Graph.swift)

---

### `POST /v1/library/document`

Groups **containing** a given document — not the document itself. Body: `{"document_id": "..."}`. There is no HTTP route that reads a document's text back; search returns only the partitions that matched.

File: [Library.swift](../../Sources/API/Routes/Library.swift)

---

### `POST /v1/clear` — destructive

Wipes this node's partition table, graph and registry. Requires `{"confirm": true}` or it returns 400. Content files under `documents/` are left alone, because co-located nodes may reference them.

Returns `{"cleared": true, "documents": N, "entities": N}`.

File: [Library.swift](../../Sources/API/Routes/Library.swift)

---

### Graph editing

Granular knowledge-graph mutation. **None of these take an `owner_id` and none are authorized** — any caller can edit any entity in the global graph.

| Route | Body | Notes |
|---|---|---|
| `POST /v1/graph/entity/rename` | `{id, name}` | A re-key on `(kind, name)`. If that identity already exists this silently becomes a merge into it. |
| `POST /v1/graph/entity/merge` | `{from, into}` | `from` stops existing; its documents and edges move. |
| `POST /v1/graph/entity/set-kind` | `{id, kind}` | Also a re-key. |
| `POST /v1/graph/entity/delete` | `{id}` | |
| `POST /v1/graph/relationship/delete` | `{id}` | |
| `POST /v1/graph/re-extract` | `{document_id, thread:{owner_id}}` | Re-runs extraction under the current policy. **Blocks** until the extractor finishes. |

All return `{"success": bool, "surviving_id"?: string, "entity_count"?: int}`.

Two behaviours callers must handle:

- **Rename, merge and set-kind change the entity id.** `surviving_id` is the id that lives; the one you sent is dead. Adopt it rather than reusing the original.
- **The two delete routes always return `success: true`**, even for an id that does not exist — they discard the store's return value. A client cannot treat the response as proof of deletion; re-query and reconcile.

Note these bodies have **no `CodingKeys` server-side**, so their keys are literal camelCase (`id`, `name`, `kind`, `from`, `into`) — unlike `owner_id`, `document_id` and friends elsewhere.

File: [GraphAdmin.swift](../../Sources/API/Routes/GraphAdmin.swift)

---

### `GET` / `PUT /v1/graph/policy`

The global extraction policy: ontology (`kinds`), prompt override, predicate aliases, caps, co-mention rule and hub guard. Changes are **prospective** — already-indexed documents keep the graph they were extracted with until they are re-extracted.

`PUT` is decoded with the synthesized initializer, so **Swift property defaults do not apply**: every non-optional key (`kinds`, `predicate_aliases`, `max_entities`, `max_relationships`) must be present or it 400s with ``Coding key `max_entities` not found.`` Send the whole policy back, not a delta.

`co_mention` is the one nested type without `CodingKeys`, so its third field is literally `skipExplicitlyLinked`, not `skip_explicitly_linked`.

File: [GraphAdmin.swift](../../Sources/API/Routes/GraphAdmin.swift)

---

## Request / Response Models

All HTTP models are in [Sources/API/Models/](../../Sources/API/Models/). They mirror the gRPC proto types but are JSON-serializable via `Codable`.

- Requests: [Requests/](../../Sources/API/Models/Requests/)
- Responses: [Responses/](../../Sources/API/Models/Responses/)

---

## Notes

- **No authentication.** `owner_id` is taken directly from the request body. Use a reverse proxy with bearer token enforcement if you expose this externally.
- In distributed mode, the HTTP routes are secondary. Sewn communicates with Thread exclusively via the gRPC session stream.
