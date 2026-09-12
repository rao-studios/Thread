# Thread Client

<p align="center">
  <img src="../README_Assets/1.png" alt="Thread Client — knowledge-graph traversal with the entity inspector open" width="860" />
</p>

A macOS operator console for a [Thread](../README.md) node: index documents,
search them, traverse and edit the knowledge graph, watch every HTTP call go
by, and read the node's on-disk state directly.

## Requirements

- macOS 14+
- A Thread node running locally (see [Build & Run](../README.md#build--run))

## Running

Open `Package.swift` in Xcode and run the **DatabaseDemo** scheme, or:

```bash
cd Client
swift run DatabaseDemo
```

It talks to `http://127.0.0.1:8081` by default — Thread's default port. Open
Settings (the gear, bottom of the sidebar) to change the node URL, the owner
id, the group, or the data directory.

> Thread has **no authentication**. `owner_id` is whatever the client says it
> is, and the graph-editing routes don't even take one. Point this at a node
> you own.

## The two lanes

The client reaches a node two different ways, and the distinction runs through
the whole UI:

| Lane | What it is |
|---|---|
| **HTTP** | Live state, and the only way to *change* anything |
| **The data directory** | Read-only, lags the node by up to a second, and the only way to see what the API doesn't expose |

## Panes

| Pane | What it does |
|---|---|
| **Search** | Queries `POST /v1/search`, and renders the graph context the response carries — which entities the query matched, which edges the one-hop expansion crossed, how many documents that pulled in beyond the vector hits |
| **Index** | Stages documents and sends them as **one** `POST /v1/batch/embeddings` call. Each row can carry its own name, tags, entities, relationships and media type — the per-document arrays the batch route aligns 1:1 with `inputs` |
| **Graph** | Force-directed canvas over `POST /v1/graph`. Click to select, double-click to expand outward, drag to pin. Rename, set kind, merge and delete live in the selection inspector |
| **Library** | Groups and documents with owner, access, `created_at` and group metadata, plus per-document "which groups contain this" and graph re-extraction |
| **Store** | The data directory, decoded straight off disk: node list, registry, true graph totals, per-document stats, and the stored partition text |
| **Inspector** | The wire log and the extraction-policy editor |

## Things worth knowing

- **Indexing is asynchronous.** A 200 from the batch route means "embedded and
  enqueued", not "searchable" — enrichment and the write queue run detached.
  The Index pane says *Accepted* rather than *Done* for that reason.
- **Documents are content-addressed** by a hash of their keyword profile, so
  re-submitting near-identical text is deduplicated rather than re-indexed.
- **Renaming an entity is a re-key.** Rename, merge and set-kind all change the
  entity id, and the response's `surviving_id` is the one that lives. Renaming
  onto a name that already exists for the same kind silently merges into it.
- **Delete always reports success**, even for an id the node has never seen, so
  the client says "removed from view" and re-queries rather than claiming a
  deletion it can't verify.
- **Browse mode is capped.** Leaving both *Entity* and *Query* empty returns the
  top `limit` entities by mention count, not the whole graph — the caption says
  when the view is truncated. The Store pane shows the real totals.

## Not available

These exist on the node but only over gRPC, so there is no control for them
here rather than a button that can't work:

- Deleting a single document, or all of an owner's documents (the only HTTP
  delete is the whole-node wipe in Settings)
- Changing a document's or group's access
- Renaming a group or editing its metadata

## Wire log

Every request funnels through one function in `ThreadAPI`, so the Inspector
pane has the complete traffic: method, URL, request JSON, status, latency and
response body — plus **Copy as curl**, which produces a command that reproduces
the call in a terminal. When something fails, that is the fastest way to tell a
client bug from a node one.

## Layout

```
Sources/Core/
├── Models/        Wire.swift (HTTP DTOs) · StoreModels.swift (on-disk mirrors)
├── Services/      ThreadAPI · StoreReader · WireLog · FileReader · TextSanitizer · HTMLExtractor
├── Graph/         GraphLayout (physics) · GraphSimulation (driver)
└── Views/         one file per pane, plus Graph/ and Store/
```

`GraphLayout` has no SwiftUI import — the force-directed simulation is plain
value types so it can be reasoned about and tested on its own.

`StoreModels` mirrors types that are `internal` to the server's executable
target and so can't be imported. They decode deliberate subsets and fail soft:
if the server renames a property, the Store pane says which file failed to
decode and why, instead of showing an empty node.
