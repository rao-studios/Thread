# Providers

Totem supports two embedding backends, selected at startup via `--use-mlx`. Both produce 1024-dimensional float32 vectors.

---

## Backends

### Mistral API (default)

`EmbeddingModelProvider` — actor-based API client for `mistral-embed`.

- Max 3 concurrent slots enforced via a priority queue. Requests beyond the limit wait in the queue until a slot opens.
- Identical texts within a batch are **coalesced** into one API call; the result is fanned back to all waiters.
- Requires `MISTRAL_API_KEY` in environment.
- Model: `mistral-embed`, 1024 dimensions.

**Adding concurrency**: change `maxConcurrentSlots` in `AppConstants`. Each slot maps to one in-flight API request.

### On-device MLX (`--use-mlx`)

`MLXEmbeddingModelProvider` — runs entirely on Apple Silicon GPU via MLX.

- Model is loaded from the Hugging Face Hub cache (`~/.cache/huggingface/hub/`) on first request.
- No API key or network access needed after download.
- Default model: `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`.
- Override with `--mlx-model <hub-model-id>`.
- Model: 1024 dimensions (must match Mistral's output dimension — PQ indices are not interchangeable between models).

**Switching models**: if you change `--mlx-model`, any existing WAL data was indexed under the old model's embedding space. Rebuild the index from scratch or use a separate data directory.

---

## Provider Protocol

Both backends conform to `EmbeddingModelProvider` (protocol defined in [EmbeddingModelProvider.swift](../../Sources/Providers/EmbeddingModelProvider.swift)):

```swift
protocol EmbeddingModelProvider {
    func embed(_ texts: [String]) async throws -> [[Float]]
}
```

To add a new backend: implement the protocol and wire it into `TotemServer.swift` as an alternative to the two existing providers.

---

## Tag Embeddings

The same provider used for document partitions is also used to embed the auto-generated or supplied `tags` array. Tag embeddings are stored separately in `PartitionIndex` and used as a pre-filter during search when `seer.tags` is set.

---

## Key Files

| File | Purpose |
|---|---|
| [EmbeddingModelProvider.swift](../../Sources/Providers/EmbeddingModelProvider.swift) | Protocol + Mistral actor implementation |
| [MLXEmbeddingModelProvider.swift](../../Sources/Providers/MLXEmbeddingModelProvider.swift) | On-device MLX implementation |
| [AppConstants.swift](../../Sources/Utilities/AppConstants.swift) | `maxConcurrentSlots`, model names, dimension constants |
