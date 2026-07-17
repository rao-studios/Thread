# API

Totem's HTTP layer is the **standalone path**. In distributed mode, all production traffic flows through the gRPC session stream with Seer. The HTTP routes remain available for direct use and debugging in both modes.

---

## Routes

### `POST /health`

Returns `{"status":"ok"}`. No auth required. Used by load balancers and Seer to verify liveness.

File: [Health.swift](../../Sources/API/Routes/Health.swift)

---

### `GET /v1/availability`

Returns current storage availability state. Seer uses this to decide whether to route new index requests to this node.

File: [Availability.swift](../../Sources/API/Routes/Availability.swift)

---

### `POST /v1/batch/embeddings`

Indexes one or more documents. Each document's text is embedded and PQ-compressed, and its entities/relationships are merged into the knowledge graph (LLM extraction runs in the detached enrichment pass when the caller supplies none). Returns immediately — enrichment + indexing happen in a detached background task.

**Request**

```json
{
  "inputs": ["A string, or...", ["array", "of", "strings"]],
  "sanitize": true,
  "seer": {
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
| `seer.owner_id` | Yes | Identity of the caller. Lowercased on receipt. |
| `seer.group` | No | Assigns all documents in this batch to a named group. |
| `sanitize` | No | When `true`, passes each input through `TextChunker`. Default: `false`. |
| `tags` | No | Per-document tag hints. Outer index aligns 1:1 with `inputs`. Auto-generated if empty. |
| `media_type` | No | `"text"` (default) or `"image"`. |

File: [BatchEmbeddings.swift](../../Sources/API/Routes/BatchEmbeddings.swift)

---

### `POST /v1/search`

Searches indexed documents for the closest matching partitions to a query string.

**Request**

```json
{
  "query": "how does product quantization work?",
  "seer": {
    "owner_id": "alice",
    "scope": "personal",
    "aggregate": false
  }
}
```

| Field | Required | Description |
|---|---|---|
| `query` | Yes | Natural language query. Embedded at search time. |
| `seer.owner_id` | Yes | Scopes the search to this owner's documents. |
| `seer.scope` | No | `personal` (default) or `global` (all `.available` documents). |
| `seer.aggregate` | No | Also searches groups the owner has access to. |
| `seer.group` / `seer.groups` | No | Restrict search to specific groups. |
| `seer.tags` | No | Tag pre-filter — only partitions within tag embedding threshold are considered. |

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

## Request / Response Models

All HTTP models are in [Sources/API/Models/](../../Sources/API/Models/). They mirror the gRPC proto types but are JSON-serializable via `Codable`.

- Requests: [Requests/](../../Sources/API/Models/Requests/)
- Responses: [Responses/](../../Sources/API/Models/Responses/)

---

## Notes

- **No authentication.** `owner_id` is taken directly from the request body. Use a reverse proxy with bearer token enforcement if you expose this externally.
- In distributed mode, the HTTP routes are secondary. Seer communicates with Totem exclusively via the gRPC session stream.
