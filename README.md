# Thread

Thread is a distributed vector search and knowledge-graph node for [Sewn](https://github.com/rao-studios/Sewn). It runs standalone as a single binary, or as one node in a fleet that a Sewn mothership fans queries across.

## Introduction

Thread is a **memory node**. You give it text; it gives back the passages that
answer a question — and the entities those passages are about.

Every document that arrives is chunked into partitions, embedded to 1024
dimensions, compressed with product quantization, and folded into a knowledge
graph of entities and relationships. A query runs against both halves at once:
the graph narrows the field, a quantized distance scan ranks what survives, and
a one-hop graph expansion pulls in documents the vectors alone would have
missed. Documents are content-addressed by a SHA-256 of their text, so the same
passage submitted twice is embedded once and stored once.

What that buys you, concretely:

| | |
|---|---|
| **Hybrid retrieval** | Knowledge graph *and* vector search in one query, not a graph bolted onto a vector store after the fact. |
| **Compressed by default** | Product quantization means a scan touches integer codes, not 4 KB float vectors — millions of partitions without loading them. |
| **On-device or hosted** | Embeddings and graph extraction run locally through MLX (Apple Silicon or CUDA) or through the Mistral API. No key needed for the local path. |
| **Deduplicated** | Content addressing collapses duplicate text across owners to one copy of the vectors. |
| **Owned, not rented** | A single binary writing plist snapshots to a directory you name. No database to run, no service to sign up for. |

Thread deliberately stops short of a few things. It has **no authentication** —
`owner_id` is whatever the caller says it is — and it holds no user sessions.
Access control is a two-value flag (`restricted` / `available`) enforced per
document, not an identity system. That is Sewn's job in a full deployment, or
your reverse proxy's in a standalone one.

It runs in one of two shapes:

```mermaid
flowchart LR
    subgraph standalone["Standalone — one node, no coordinator"]
        direction TB
        C1["Your client"] -->|"HTTP :8080"| T1["Thread"]
        T1 --> D1[("thread-db")]
    end

    subgraph distributed["Distributed — a fleet behind Sewn"]
        direction TB
        C2["Your client"] --> S["Sewn<br/>mothership"]
        S -.->|"fan-out over<br/>one session stream"| N1["Thread A"]
        S -.-> N2["Thread B"]
        S -.-> N3["Thread C"]
        N1 --> DB1[("db")]
        N2 --> DB2[("db")]
        N3 --> DB3[("db")]
    end

    standalone ~~~ distributed
```

In distributed mode **Thread dials Sewn**, not the other way round: the node
registers itself, then holds a bidirectional stream open and serves requests
that arrive down it. A node behind NAT needs no inbound port. The HTTP routes
stay live in both shapes for direct use and debugging.

### Part of MaryOS

Thread was built for **MaryOS**, Rao Studios' ambient-computing stack, and that
is where its shape comes from. MaryOS puts an assistant on hardware you own and
keeps what she learns there; Thread is the part that remembers. The design
choices above all follow from that brief — on-device embeddings because memory
should not have to leave the machine, content addressing because the same
passage arrives from a dozen places, a knowledge graph because *"what do you
know about me?"* is a question about entities, not cosine distance.

The stack is a set of independent Swift packages, each usable on its own:

| Repository | Role |
|---|---|
| [Mary](https://github.com/rao-studios/Mary) | The macOS assistant — screen perception through the accessibility tree, voice, declarative Plugins. Thread is her only durable memory. |
| [Sewn](https://github.com/rao-studios/Sewn) | The mothership — authentication, conversation and RAG pipelines, and fan-out across every registered Thread node. |
| **Thread** | *This repository.* The memory node: vector storage, knowledge graph, retrieval. |
| [Fleet](https://github.com/rao-studios/Fleet) | Trains LoRA adapters on real turns pulled back out of Thread, so small on-device models emit a fixed schema. |
| [Conduit](https://github.com/rao-studios/Conduit) | The wire — one canonical set of `.proto` files and the session machinery every mothership and node links against. |
| [Frigate](https://github.com/rao-studios/Frigate) | The self-contained MLX stack behind Thread's on-device embeddings and graph extraction. |
| [MaryUI](https://github.com/rao-studios/MaryUI) | The desktop design system, theme *Liquid Platinum*. |
| [MaryPi](https://github.com/rao-studios/MaryPi) | MaryOS as a bootable Ubuntu arm64 image for the Raspberry Pi 5. |

None of it is required to run Thread. It is a standalone binary with HTTP routes
and no dependency on Sewn, and most of this README treats it that way.
[Thread in practice — MaryOS](#thread-in-practice--maryos) walks through the
whole deployment once the mechanics are on the table — it is the worked example
for everything below.

## Sewn

[Sewn](https://github.com/rao-studios/Sewn) is the mothership server that coordinates a fleet of Thread nodes. It handles authentication (via Supabase), conversation and RAG pipelines, sentiment analysis (Sinatra), royalty tracking (Gita), and personalization (Marielle). When a user issues a search or index request through Sewn, Sewn fans the operation out to all registered Thread nodes in parallel and merges the results.

Thread owns no user sessions and no authentication — that is Sewn's responsibility. Thread's sole job is fast, reliable vector storage and nearest-neighbor search.

## Prerequisites

### macOS (Apple Silicon)

- Xcode 16 / Swift 6.3+
- macOS 15+
- A [Mistral API key](https://console.mistral.ai/) (for Mistral embeddings) **or** Apple Silicon (for on-device MLX)

### Linux (Ubuntu 24.04 + NVIDIA GPU)

- Ubuntu 24.04 LTS (Noble)
- NVIDIA GPU — RTX 3080 / 3090 / 4080 / 4090 / A100 / H100
- Internet access for the one-time setup

---

## Setup

### macOS

```bash
# Mistral embeddings (requires API key)
cp .env.example .env
# Edit .env and set MISTRAL_API_KEY

# On-device MLX (no key needed — downloads ~500 MB model once)
pip3 install huggingface_hub
python3 -m huggingface_hub download mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ
```

Build and run:

```bash
swift build -c release
.build/release/thread --host 127.0.0.1 --port 8080 --use-mlx
```

### Linux / Ubuntu 24.04 (NVIDIA GPU)

**One-time machine setup** — installs Swift 6.3.2, CUDA 12.9, LAPACK, and the cuDNN Frontend headers:

```bash
chmod +x setup-cuda-ubuntu.sh
./setup-cuda-ubuntu.sh
```

After the script finishes, open a new terminal (or `source ~/.bashrc`) so the CUDA and Swift paths are live.

**Download the embedding model** (one-time, ~500 MB):

```bash
python3 -m huggingface_hub download mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ
```

**Build:**

```bash
chmod +x build-linux-cuda.sh
./build-linux-cuda.sh           # debug CUDA build (default)
./build-linux-cuda.sh --debug   # explicit debug
```

> `CUDA_ARCH` defaults to `sm_86` (RTX 30xx / A100). Override for other GPUs:
> ```bash
> CUDA_ARCH=sm_89 ./build-linux-cuda.sh   # RTX 40xx
> CUDA_ARCH=sm_90 ./build-linux-cuda.sh   # H100
> ```

**Run:**

```bash
.build/debug/thread --host 127.0.0.1 --port 8080 --use-mlx
```

The package is pinned to `riteshpakala/mlx-swift:gab/cuda1` which carries patches for CUDA 12.9 + GCC 13 half-precision math, CUTLASS-free sm_86 builds, SDPA cache sizing, and a GPU-only affine quantized matmul fallback. See [Docs/MLX-CUDA-Linux.md](Docs/MLX-CUDA-Linux.md) for the full patch log, fork commit hashes, and troubleshooting reference.

## Build & Run

**macOS**

```bash
swift build -c release

# Standalone — HTTP only, no Sewn required
.build/release/thread --host 127.0.0.1 --port 8080

# On-device MLX (Apple Silicon)
.build/release/thread --host 127.0.0.1 --port 8080 --use-mlx

# Distributed — registers with a running Sewn instance
.build/release/thread \
  --host 127.0.0.1 --port 8080 \
  --grpc-port 9090 \
  --mothership-host 127.0.0.1 \
  --mothership-grpc-port 50051
```

**Linux / Ubuntu 24.04**

```bash
./build-linux-cuda.sh

# Standalone with on-device GPU embeddings
.build/debug/thread --host 127.0.0.1 --port 8080 --use-mlx

# Distributed
.build/debug/thread \
  --host 127.0.0.1 --port 8080 \
  --grpc-port 9090 \
  --mothership-host 127.0.0.1 \
  --mothership-grpc-port 50051 \
  --use-mlx
```

Check health:

```bash
curl http://127.0.0.1:8080/health
# {"status":"ok"}
```

### CLI flags

| Flag | Default | Description |
|---|---|---|
| `--host` | `127.0.0.1` | HTTP bind address |
| `--port` | `8081` | HTTP port |
| `--grpc-port` | `9090` | gRPC listen port (distributed mode) |
| `--data-dir` | `~/Documents/thread-db` | Directory for on-disk state (env `THREAD_DATA_DIR`) |
| `--node-id` | _(persisted)_ | Fixed node UUID. Overrides the `node-id` on disk — pins `table-<uuid>` across restarts |
| `--mothership-host` | _(empty)_ | Sewn host — leave unset for standalone mode |
| `--mothership-grpc-port` | `9091` | Sewn gRPC port |
| `--fleet-host` | _(empty)_ | Fleet host for dataset import — leave unset to skip |
| `--fleet-grpc-port` | `9092` | Fleet gRPC port |
| `--use-mlx` | `false` | Use on-device MLX embeddings (Apple Silicon / CUDA builds only) |
| `--mlx-model` | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` | Hub model ID for MLX embeddings |
| `--graph-backend` | `mlx` | Graph extraction backend: `mlx` (on-device), `mistral` (API), or `keyword` |
| `--graph-model` | `mlx-community/Qwen3-1.7B-4bit` | Hub model ID for on-device graph extraction |
| `--graph-mistral-model` | `mistral-tiny` | Model used when `--graph-backend mistral` |
| `--no-graph-extraction` | `false` | Disable LLM extraction (keyword entities only) |

> `--graph-backend mlx` degrades to keyword-only extraction if the build has no
> Metal kernel library — MLX would otherwise abort the process on first use.
> Thread logs a warning and carries on; pass `--graph-backend mistral` for API
> extraction, or rebuild Frigate with its metallib step.

---

## Architecture

```mermaid
flowchart TB
    subgraph sewn["Sewn — mothership"]
        SC["ThreadQuery client<br/><i>fan-out: search · index · remove<br/>library · graph</i>"]
    end

    subgraph thread["Thread — this repo"]
        subgraph conduit["Conduit layer"]
            MRC["MothershipRegistrationClient<br/><i>register → session → updateAvailability</i>"]
            DISP["MothershipRequestDispatcher<br/><i>routes on the payload oneof</i>"]
            SVC["gRPC services<br/><b>ThreadQuery</b> · <b>ThreadLibrary</b> · <b>ThreadGraph</b>"]
        end

        subgraph db["Database — actor"]
            RM["RegistryMutator"] --> REG["ThreadRegistry<br/><i>owners · groups · access</i>"]
            TM["TableMutator"] --> PT["PartitionTable<br/><i>PartitionIndex × M</i>"]
            TM --> GS["GraphStore<br/><i>entities + relationships</i>"]
            PT --> PQ["PartitionQuantizer<br/><i>PQ codebooks · ADC</i>"]
        end

        HTTP["HTTP routes<br/><i>standalone path</i>"]
    end

    SC <-->|"one bidirectional<br/>session stream"| MRC
    MRC --> DISP
    DISP --> SVC
    SC -.->|"direct gRPC,<br/>bypassing the stream"| SVC
    HTTP --> RM
    SVC --> RM
    SVC --> TM
    REG --> SNAP[("plist snapshots<br/>--data-dir")]
    PT --> SNAP
    GS --> SNAP
```

**Thread holds the connection.** Sewn never dials the node — Thread registers
itself and keeps one stream open, so a node behind NAT needs no inbound port.
The same three services are reachable directly on `--grpc-port` for any client
that would rather skip the mothership; [MaryOS](#thread-in-practice--maryos)
takes that path.

### Registration & session lifecycle

When `--mothership-host` is provided, `MothershipRegistrationClient` starts a persistent loop:

1. **`register` RPC** — Thread sends its UUID, HTTP host, gRPC port, and HTTP port. Sewn records the node and returns an acceptance signal. Thread retries every 5 s until accepted.
2. **`session` RPC** — Thread opens a bidirectional stream and holds it. Thread sends periodic pings every 30 s. Sewn sends request payloads (search, index, remove, library, graph, update, stats) over the same stream. `MothershipRequestDispatcher` routes each message to the correct service impl and writes the response back with a matching `correlationID`.
3. **`updateAvailability` RPC** — A one-shot call Thread makes when its storage capacity changes (e.g. after a large batch completes). Sewn uses this to steer new index requests to nodes that are accepting storage.

If the session drops, `MothershipRegistrationClient` sleeps 5 s and reconnects automatically.

---

## gRPC Services

All services run on `--grpc-port` (default 9090) and are also reachable via the Sewn session stream.

### ThreadQuery

| RPC | Request | Response | Description |
|---|---|---|---|
| `Search` | `ThreadSearchRequest` | `ThreadSearchResponse` | Hybrid KG + PQ search. Accepts raw `query_text` (Thread embeds it) or a precomputed `query_embedding`; optional `entities` gate the graph pre-filter. The response carries a `trace` describing entity matches and graph expansion. |
| `Index` | `ThreadIndexRequest` | `ThreadIndexResponse` | Embed and index a batch of documents. Returns immediately; async write queue drains in the background. |
| `Remove` | `ThreadRemoveRequest` | `ThreadRemoveResponse` | Remove specific document IDs, or all documents for an owner when `document_ids` is empty. |

### ThreadLibrary

| RPC | Request | Response | Description |
|---|---|---|---|
| `Library` | `ThreadLibraryRequest` | `ThreadLibraryResponse` | Paginated list of groups for an owner. `after_id` is a cursor; `limit` controls page size. Passing `document_ids` takes a reverse-map fast path instead of scanning the library — the document-id → group lookup. |
| `Documents` | `ThreadDocumentsRequest` | `ThreadDocumentsResponse` | Full document content by id, reassembled from the stored partition texts in order. Access mirrors search: caller-owned or publicly available; anything else is silently omitted. |
| `ExportCorpus` | `ThreadExportCorpusRequest` | `ThreadExportCorpusResponse` | Paged full-document export, filtered by group and by `document_id_prefix`. For training pipelines that must read whole documents rather than reconstruct them from search snippets. |

### ThreadGraph

| RPC | Request | Response | Description |
|---|---|---|---|
| `Query` | `ThreadGraphQueryRequest` | `ThreadGraphQueryResponse` | Resolve seed entities by name and/or free-text similarity (Thread embeds `query`), traverse up to `hops` edges (0–3), and return entities, relationships, linked documents, and graph stats. |

### Session message envelope

Every payload traveling over the `Session` stream is wrapped in `ThreadSessionMessage`:

```protobuf
message ThreadSessionMessage {
  string correlation_id = 1;   // ties each request to its response
  string thread_id       = 2;   // set by Thread so Sewn can identify the stream

  oneof payload {
    ThreadSessionPing            ping                     = 3;
    ThreadSessionPong            pong                     = 4;
    ThreadSearchRequest          search_request           = 5;
    ThreadSearchResponse         search_response          = 6;
    ThreadIndexRequest           index_request            = 7;
    ThreadIndexResponse          index_response           = 8;
    ThreadRemoveRequest          remove_request           = 9;
    ThreadRemoveResponse         remove_response          = 10;
    ThreadLibraryRequest         library_request          = 11;
    ThreadLibraryResponse        library_response         = 12;
    // 13–22 reserved (retired ThreadHNSW arms)
    ThreadUpdateGroupRequest     update_group_request     = 23;
    ThreadUpdateGroupResponse    update_group_response    = 24;
    ThreadUpdateDocumentRequest  update_document_request  = 25;
    ThreadUpdateDocumentResponse update_document_response = 26;
    ThreadStatsRequest           stats_request            = 27;
    ThreadStatsResponse          stats_response           = 28;
    ThreadGraphQueryRequest      graph_request            = 29;
    ThreadGraphQueryResponse     graph_response           = 30;
  }
}
```

`MothershipRequestDispatcher` reads the `payload` oneof, calls the matching service impl, and returns a response message with the same `correlation_id`.

---

## Core Services

### Registry

The `ThreadRegistry` is the ownership and access-control layer. Every document must be registered to an owner before it can be searched.

| Concept | What it is |
|---|---|
| `ownerId` | Arbitrary string identifying the caller — passed in the request body (no auth middleware) |
| `DocumentID` | SHA-256 hash of the document's text chunks — content-addressed, collision-safe |
| `GroupID` | Owner-defined namespace that bundles documents together |
| `Access` | `.available` (globally searchable) or `.restricted` (owner-only, default) |

Documents are **deduplicated by content**: if two owners embed the same text, only one copy of the vectors is stored. The second owner is linked to the existing document automatically.

### Groups

Groups are logical collections owned by a single owner. Documents inside a group share metadata (tags, description) that surfaces in search. Access on the group propagates to all documents inside it.

```json
"group": {
  "id": "my-group",
  "label": "My Knowledge Base",
  "owner_id": "alice",
  "documents": [],
  "access": "restricted",
  "metadata": {
    "description": "Internal docs",
    "tags": ["swift", "server"]
  }
}
```

### Partition Table & Knowledge Graph

Each document is split into text chunks (partitions). Each partition gets a 1024-dimensional embedding. State lives in:

- **PartitionIndex** — per-document index holding PQ-compressed vectors, an entity embedding, learned codebooks, entity linkage, and an optional metadata blob.
- **PartitionTable** — flat map of document indices; search is a parallel per-document ADC scan with an entity pre-filter.
- **GraphStore** — the knowledge graph: content-addressed entities (`(kind, normalized name)` merges the same concept across documents), weighted relationships, and document-provenance sets that link the graph back to the vector store.

At search time, query entities are matched against the graph (name tokens + embedding cosine), the entity pre-filter narrows candidates, the ADC scan ranks partitions, and a one-hop graph expansion pulls in documents linked to neighboring entities (scored with a small penalty so direct hits win ties).

Entities and relationships arrive with the request, or are extracted on-device by a small LLM (`--graph-model`, default Qwen3-1.7B-4bit) in a detached post-response pass — keyword entities serve as the always-available fallback.

### Product Quantization (PQ)

Embeddings are compressed at index time via `PartitionQuantizer`. Each 1024-float vector is encoded into a compact `UInt16` code sequence using learned k-means codebooks. Search uses Asymmetric Distance Computation (ADC) against pre-computed distance tables — fast enough to scan millions of partitions without loading full vectors.

Codebook size scales dynamically with the training corpus (`scaledCodebookSize`): a document with 3 partitions uses k=2; a large shared index may grow to k=2048 or higher. An `adaptiveThreshold` is calibrated per-document from reconstruction errors during training and overrides the static per-codec fallback at search time.

If all partitions in a batch fail embedding (e.g. empty text), Thread skips index creation for that document and logs a warning rather than crashing.

### Persistence

All state persists as binary plist snapshots (`table-<nodeId>`, `graph-<nodeId>`, `registry`, `documents/*`) with a 1-second debounced save on the hot path and immediate saves for removes and shutdown.

On startup, two reconciliation sweeps close the debounce crash window: orphaned table documents are removed (and detached from the graph), and registry documents missing a table index are dropped so re-ingest is not blocked by the dedup check. Legacy shard/WAL artifacts from the previous HNSW format are purged automatically.

### EmbeddingModelProvider

Two backends, selected at startup with `--use-mlx`:

| Backend | Flag | Model | Dimensions |
|---|---|---|---|
| Mistral API (default) | _(none)_ | `mistral-embed` | 1024 |
| On-device MLX | `--use-mlx` | `Qwen3-Embedding-0.6B-4bit-DWQ` (default) | 1024 |

**Mistral** — Actor-based API client. Max 3 concurrent slots with a priority queue; identical texts within a batch are coalesced into one request. Requires `MISTRAL_API_KEY`.

**MLX** — Runs entirely on-device via Apple Silicon GPU. Model is loaded from the Hugging Face Hub cache on first request. No API key or network access needed after download. Use `--mlx-model` to specify a different Hub model ID.

---

## HTTP Routes

The HTTP routes are the **standalone path**. In distributed mode all production traffic flows through the gRPC session stream; the HTTP routes remain available for direct use and debugging.

### `POST /v1/batch/embeddings`

Indexes one or more documents. Each document's text is embedded and PQ-compressed, and its entities/relationships are merged into the knowledge graph (LLM extraction runs when the caller supplies none). The response is returned immediately — enrichment + indexing happen in a detached background task.

**Request**

```json
{
  "inputs": [
    "A string, or...",
    ["array", "of", "strings"]
  ],
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
  "tags": [
    ["optional", "per-document", "tags"],
    ["second-doc-tags"]
  ],
  "media_type": "text"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `inputs` | `[String \| [String]]` | Yes | One entry per document. String or array of strings. |
| `thread.owner_id` | String | Yes | Identity of the caller. Lowercased on receipt. |
| `thread.group` | Group | No | Assigns all documents in this batch to a named group. |
| `sanitize` | Bool | No | When `true`, passes each input through `TextChunker` before embedding. Default: `false`. |
| `tags` | `[[String]]` | No | Per-document tag hints. Outer index aligns 1:1 with `inputs`. Auto-generated if empty. |
| `media_type` | String | No | `"text"` (default) or `"image"`. |

**Response**

```json
{
  "object": "list",
  "model": "mistral-embed",
  "usage": { "prompt_tokens": 312, "total_tokens": 312 },
  "success": true,
  "user": { ... }
}
```

---

### `POST /v1/search`

Searches indexed documents for the closest matching partitions to a query string.

**Request**

```json
{
  "query": "how does product quantization work?",
  "thread": {
    "owner_id": "alice",
    "group": { "id": "my-group", "label": "...", "owner_id": "alice", "documents": [] },
    "scope": "personal",
    "aggregate": false
  }
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `query` | String | Yes | Natural language query. Embedded at search time. |
| `thread.owner_id` | String | Yes | Scopes the search to this owner's documents by default. |
| `thread.scope` | `"personal" \| "global"` | No | `personal` (default): only the owner's documents. `global`: all `.available` documents. |
| `thread.aggregate` | Bool | No | When `true`, also searches groups the owner has access to. |
| `thread.group` | Group | No | Restricts search to a specific group. |
| `thread.groups` | [Group] | No | Restricts search to a list of groups. |
| `thread.tags` | [String] | No | Tag filter: only documents whose tag embedding is within threshold are considered. |

**Response**

```json
{
  "object": "list",
  "texts": ["...most relevant partition text...", "...second result..."],
  "references": [
    { "document_id": "abc123", "partition_id": "def456", "distance": 0.12 }
  ]
}
```

`texts` and `references` are parallel arrays.

---

## Workflow Example

### 1 — Embed documents

```bash
curl -X POST http://127.0.0.1:8080/v1/batch/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [
      "Swift actors serialize concurrent access by routing all calls through a single executor.",
      "Product quantization compresses high-dimensional vectors into compact integer codes."
    ],
    "thread": {
      "owner_id": "alice",
      "group": {
        "id": "swift-docs",
        "label": "Swift Documentation",
        "owner_id": "alice",
        "documents": []
      }
    }
  }'
```

### 2 — Search

```bash
curl -X POST http://127.0.0.1:8080/v1/search \
  -H "Content-Type: application/json" \
  -d '{
    "query": "how do actors work in Swift?",
    "thread": {
      "owner_id": "alice",
      "scope": "personal"
    }
  }'
```

### 3 — Share documents publicly (optional)

Documents are `.restricted` by default. To make a document globally searchable, set the group's `"access": "available"`:

```json
"group": {
  "id": "public-docs",
  "label": "Public Documentation",
  "owner_id": "alice",
  "documents": [],
  "access": "available"
}
```

Another owner can then find it with `"scope": "global"`.

---

## Thread in practice — MaryOS

MaryOS is the reference consumer, and the one that exercises every part of this
node. [Mary](https://github.com/rao-studios/Mary) — its macOS assistant — is an
ambient-intelligence agent: she watches the screen through the accessibility
tree, carries out declarative Plugins by voice, speaks through Sewn, and
**remembers through Thread**. Thread is the only durable memory she has; there
is no second store, no local database, no file of notes on the side.

It is worth reading even if you never touch Mary, because it is a worked answer
to the questions this README leaves open: how do you address documents when the
library returns no metadata? What belongs in a group versus a document? When is
a graph edge worth writing?

### The stack

Mary runs the whole stack locally as supervised child processes, one data
directory per server, and talks to each over loopback gRPC:

```mermaid
flowchart LR
    subgraph app["Mary.app"]
        RT["MaryRuntime"]
        TCS["ThreadContextStore<br/><i>actor</i>"]
        TDC["ThreadDirectClient<br/><i>MaryThread</i>"]
        RT --> TCS --> TDC
    end

    SEWN["<b>Sewn</b><br/>HTTP :8080<br/>gRPC :9091"]
    THREAD["<b>Thread</b><br/>HTTP :8081<br/>gRPC :9090"]
    FLEET["<b>Fleet</b><br/>HTTP :8083<br/>gRPC :9093"]
    DB[("~/Documents/maryOS/<br/>thread-db")]

    TDC ==>|"ThreadQuery · ThreadLibrary · ThreadGraph<br/><b>direct, not via the mothership</b>"| THREAD
    THREAD -.->|"registers + holds<br/>the session stream"| SEWN
    SEWN -->|"writes memory- and<br/>resonance- groups"| THREAD
    FLEET -->|"ThreadLibrary.ExportCorpus<br/><i>LoRA training pairs</i>"| THREAD
    THREAD --> DB
```

Mary launches the node with an explicit identity and storage root — the node
UUID pins `table-<uuid>` across restarts, so a relaunch resumes the same
database rather than minting a fresh one:

```bash
thread \
  --host 127.0.0.1 --port 8081 \
  --grpc-port 9090 \
  --mothership-host 127.0.0.1 \
  --mothership-grpc-port 9091 \
  --data-dir ~/Documents/maryOS/thread-db \
  --node-id <persisted UUID> \
  --graph-backend mistral
```

Two things in that diagram are worth pausing on.

**Mary bypasses the mothership for her own traffic.** Thread still registers
with Sewn and holds the session stream open, but `ThreadDirectClient` dials
`127.0.0.1:9090` and speaks to the three services directly — a fresh plaintext
HTTP/2 connection per call, because the calls are sparse and the user may
restart the node from the Servers panel mid-session. Sewn remains in the
picture for authentication (Mary reads `ownerID` from the Sewn session) and for
its own writes.

**Two writers share one node.** Sewn writes `memory-<owner>` and
`resonance-<owner>` groups on its own; Mary writes everything prefixed `mary-`.
Neither may rewrite the other's, so Mary's repair and cleanup passes classify
every address before touching it.

### Memory topology: two lanes

Mary splits what she knows into two lanes, and the split is enforced by the
group id alone:

```mermaid
flowchart TB
    subgraph ability["Ability lane — transferable craft"]
        AG["<code>mary-ability-…</code><br/><i>one group per Ability × paradigm</i>"]
        AD["<code>mary-behavior-…</code><br/>sealed BehavioralEpisode"]
        ASD["<code>mary-ability-schema-…</code><br/>one learned fact per document"]
        ASM["<code>mary-ability-schema-manifest-…</code><br/>active-fact catalogue"]
        AG --- AD & ASD & ASM
    end

    subgraph personal["Personal lane — this user, this machine"]
        PG["<code>mary-scope-…</code> · <code>mary-style-…</code><br/><code>mary-routing-…</code> · <code>mary-habit-…</code>"]
        PD["<code>mary-doc-…</code> state snapshots<br/><code>mary-unit-…</code> project units<br/><code>mary-style-profile-…</code> tenets<br/><code>mary-routing-…</code> settled habits<br/><code>mary-behavior-interaction-…</code> stubs"]
        PG --- PD
    end

    subgraph sewnlane["Sewn-owned — Mary never rewrites these"]
        SG["<code>memory-…</code><br/><code>resonance-…</code>"]
    end

    ability & personal & sewnlane --> NODE["one Thread node"]
```

The Ability lane holds what would still be true for a different user: how an
application behaves, which skill satisfies which intent. The Personal lane holds
what is true only here — style, routing habits, the shape of an open project. A
sealed episode goes to Ability; Personal keeps only an interaction stub, joined
back by turn UUID.

> **Why prefixes carry the meaning.** `ThreadLibrary.Library` returns groups and
> their document ids — not tags, not metadata. So Mary encodes the family into
> the id itself and classifies by longest-matching prefix. It is a constraint of
> this API turned into a design: an id is the one field you can always read
> back. If you build on Thread, budget for the same thing.

### Writing: a turn becomes a document

When Mary finishes a turn, the assembler seals a `BehavioralEpisode` and deposits
it. The deposit is one `ThreadQuery.Index` call carrying pre-extracted entities
and relationships, so Thread does not have to infer them:

```mermaid
sequenceDiagram
    autonumber
    participant A as BehavioralAssembler
    participant S as ThreadContextStore
    participant C as ThreadDirectClient
    participant T as Thread · ThreadQuery
    participant G as GraphStore + PartitionTable

    A->>S: append(sealed episode)
    S->>S: ownerID from Sewn session
    Note over S: no owner, or no ability<br/>targets → deposit dropped
    S->>S: encode via BehavioralCodec
    S->>S: mint the mary-behavior- id,<br/>address the ability group
    S->>C: deposit(DepositItem)
    C->>T: Index(documentID, texts, tags,<br/>name, metadata, entities, relationships)
    T-->>C: indexedCount
    Note over T: responds before enrichment —<br/>the caller is not held
    C-->>S: count
    S-->>A: deposited
    T->>G: chunk → embed → PQ compress
    T->>G: merge entities, weight relationships
    G->>G: debounced plist snapshot
```

The `DepositItem` is the full shape Thread accepts on index: a caller-chosen
`documentID` (so a re-deposit *replaces* rather than accumulates), the partition
texts, tags, a display name, an opaque metadata blob, and the graph payload.
Because Mary already knows the entities involved in a turn, she supplies them —
Thread's on-device LLM extraction is the fallback for callers who don't, not the
primary path.

### Reading: four shapes of recall

Mary reads from Thread three different ways — and Fleet, training on her
history, adds a fourth. Which one a caller reaches for says a lot about what
each is actually for:

```mermaid
flowchart LR
    Q1["Did the user do<br/>this before?"] --> S1["<b>ThreadQuery.Search</b><br/>scope personal · topK · groupIds<br/>Thread embeds the query"] --> R1["ranked partitions<br/><i>routing habits, style</i>"]
    Q2["What is in<br/>this group?"] --> S2["<b>ThreadLibrary.Library</b><br/>cursor paging via after_id"] --> R2["groups + document ids<br/><i>inspection, cleanup</i>"]
    Q3["What does Mary know<br/>about <i>X</i>?"] --> S3["<b>ThreadGraph.Query</b><br/>seed by name or free text<br/>hops 0-3"] --> R3["entities, edges,<br/>linked documents"]
    Q4["Train a LoRA<br/>on real turns"] --> S4["<b>ThreadLibrary.ExportCorpus</b><br/>prefix mary-behavior-"] --> R4["whole documents<br/><i>never search snippets</i>"]
```

Two of those are load-bearing beyond Mary:

- **Search embeds server-side.** Mary sends `query_text`, not a vector. Thread
  embeds it with whatever backend it was launched with, which means Mary never
  has to match Thread's embedding model or dimensionality.
- **Training reads whole documents.** Fleet pulls `ExportCorpus` rather than
  reusing search results, because a search returns the best-matching *partition*
  — the fragment that matched, not the record. Reconstructing training pairs
  from snippets would teach the model from truncated evidence.

### Graph browse: the zero-seed query

One idiom worth stealing: `ThreadGraph.Query` with an empty `entity` **and** an
empty `query` is browse mode. It returns whole-graph statistics and the top
entities by mention count, which is how Mary renders "what do you actually know
about me?" without holding a second index:

```mermaid
flowchart LR
    B["entity: ''<br/>query: ''<br/>hops: 0"] --> GQ["ThreadGraph.Query"]
    GQ --> ST["entityCount<br/>relationshipCount<br/>top entities by mention"]
```

---

## Notes

- **No authentication.** `owner_id` is taken directly from the request body. Use a reverse proxy (nginx, Caddy) with bearer token enforcement if you expose this to the internet.
- **Persistence.** The table, graph, and registry are persisted as plist snapshots under the data directory. Do not delete these while the server is running.
- **Deduplication.** Document IDs are SHA-256 hashes of their content. Submitting the same text twice under a different owner links the second owner to the existing vectors — no re-embedding occurs.
- **Tag auto-generation.** If no `tags` are supplied, `TagGenerator` derives frequency-weighted keywords from the text. These are embedded separately and used as a pre-filter during search.
- **Distributed mode.** In distributed mode all fan-out goes through the gRPC session stream. The HTTP routes remain available for direct use and debugging. Multiple Thread nodes can run simultaneously; Sewn fans search queries to all active nodes in parallel and merges results.

---

## Skills

Detailed internals and operational docs live in [`Skills/`](Skills/SKILLS.md):

| Skill | Contents |
|---|---|
| [Database](Skills/Database/README.md) | PartitionTable, GraphStore, PQ, Registry, search and index flows |
| [GRPC](Skills/GRPC/README.md) | Service impls, session stream, mothership registration, dispatcher |
| [Providers](Skills/Providers/README.md) | Mistral API provider, on-device MLX provider |
| [Concurrency](Skills/Concurrency/README.md) | Database actor, RegistryMutator, TableMutator, caching primitives |
| [Persistence](Skills/Persistence/README.md) | Plist snapshots, debounced saves, startup reconciliation |
| [API](Skills/API/README.md) | HTTP routes in standalone mode, request/response shapes |

## Docs

Setup and operational guides:

| Guide | Contents |
|---|---|
| [MLX on Linux / CUDA](Docs/MLX-CUDA-Linux.md) | Full CUDA build setup on Ubuntu 24.04 — dependencies, fork patches, CUDA arch selection, troubleshooting |
