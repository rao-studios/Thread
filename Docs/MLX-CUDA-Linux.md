# MLX on Linux with CUDA — Build & Runtime Field Notes

Full record of every patch, fork, commit hash, and runtime quirk required to run Thread with on-device MLX embeddings on Ubuntu 24.04 + CUDA 12.9 (RTX 3090, sm_86). Intended as a living reference for re-applying changes when syncing forks against upstream.

---

## Target environment

| Component | Value |
|---|---|
| OS | Ubuntu 24.04 LTS |
| GPU | NVIDIA RTX 3090 (sm_86) |
| CUDA Toolkit | 12.9 |
| GCC | 13 |
| Swift | 6.3.2 (swiftly) |
| Model | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` |

---

## Fork map

All patches live on these forks/branches. `swift package update` advances the resolved commit to the latest on each branch — the patches are permanent there, so that is safe.

| Fork | Branch | Role | Current tip |
|---|---|---|---|
| `riteshpakala/mlx` | `gab/cuda1` | C++ MLX backend — math, stubs, GPU fallback, SDPA cache | `4d864085` |
| `riteshpakala/mlx-swift` | `gab/cuda1` | SwiftPM package — Package.swift, CudaBuild.json | `1bd613d` |
| `riteshpakala/swift-transformers` | `main` | Hub downloader — Linux API compat | `56f4dd1` |
| `riteshpakala/mlx-swift-lm` | `main` | MLX LM — CGSize stub, AVFoundation guards | `c25e0bd` |
| `riteshpakala/mlx.embeddings` | `main` | Embedding models — dependency pointers | `4f664d9` |

`Thread/Package.swift` pins all of these. The mlx C++ library is a git submodule inside `mlx-swift`; SwiftPM initialises it automatically via `.gitmodules`.

---

## Commit log by repo

### riteshpakala/mlx — gab/cuda1

| Hash | What |
|---|---|
| `4d864085` | Raise SDPA kernel cache default 256 → 2048 |
| `119de463` | Fix CublasGemm b\_rows/b\_cols logical vs physical dimension confusion |
| `bc5c40dc` | GPU fallback for affine quantized matmul on sm\_86 (dequantize + cuBLAS GEMM) |
| `ed849611` | CUTLASS-free stubs: no\_qmm\_impl.cpp, no\_fp\_quantize\_impl.cpp, no\_cutlass\_gemm\_impl.cpp |
| `47226cee` | Use standard system path for lapack.h (angled include, requires liblapacke-dev) |
| `b0805955` | Half-precision math ambiguity fix in unary\_ops.cuh / binary\_ops.cuh |

### riteshpakala/mlx-swift — gab/cuda1

| Hash | What |
|---|---|
| `1bd613d` | Bump mlx submodule to 4d864085 (SDPA cache fix) |
| `04c6cce` | CudaBuild.json: exclude qmm/, fp\_quantize.cu, qqmm\_utils.cu, grouped\_gemm\_unaligned.cu; Package.swift: exclude qqmm\_impl.cpp and cublas\_qqmm.cpp; add CUDA/cuDNN include paths |
| `862693e` | Use /usr/local/cudnn-frontend (machine-agnostic system path, set by setup script) |
| `5d37696` | Linux CUDA 12.9 build: CUTLASS exclusion, cudnn-frontend, submodule fork redirect |
| `971c7c8` | Add `-allow-unsupported-compiler` for clang 20+ with CUDA 12.9 |

### riteshpakala/swift-transformers — main

| Hash | What |
|---|---|
| `56f4dd1` | Linux compat: remaining Foundation API guards |
| `b49c43c` | Fix Linux download path: split httpGet into Darwin/Linux branches |
| `ef9d952` | Fix background URLSession, `bytes`, `autoreleasepool` for Linux |
| `98ce5a7` | Replace `String(localized:)` with plain string literals |
| `1612797` | `FoundationNetworking` import, `CFNumberIsFloatType` guard |

### riteshpakala/mlx-swift-lm — main

| Hash | What |
|---|---|
| `c25e0bd` | LinuxCompat.swift: CGSize stub; guard AVFoundation/CoreImage imports in UserInput.swift and ChatSession.swift |
| `9e00b7c` | Point mlx-swift dependency to gab/cuda1 branch |

### riteshpakala/mlx.embeddings — main

| Hash | What |
|---|---|
| `4f664d9` | Point mlx-swift dependency to gab/cuda1 branch |

### Thread — hummingbird

| Hash | What |
|---|---|
| `1de9e99` | Fix actor race: serialize concurrent MLX model loads with a shared Task |
| `5d1f566` | MLX CUDA Linux build support: scripts, docs, and provider fix |

---

## System setup

Run `./setup-cuda-ubuntu.sh` on a fresh Ubuntu 24.04 machine. It installs:

- CUDA 12.x toolkit from NVIDIA's repo
- `liblapack-dev liblapacke-dev` (LAPACK + C interface header `lapack.h`)
- cuDNN Frontend headers cloned to `/usr/local/cudnn-frontend` (header-only, no build needed)

Build with `./build-linux-cuda.sh`, which sets:

```bash
export PATH=/usr/local/cuda/bin:${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
export CUDA_ARCH=sm_86
export SPM_CUDA=1
swift build -c debug --jobs 2   # or -c release
```

Run with the MLX backend:

```bash
.build/debug/thread --host 127.0.0.1 --port 8080 --use-mlx
```

---

## Build patches

### 1 — Half-precision math ambiguity (`unary_ops.cuh`, `binary_ops.cuh`)

**Why it breaks:** CUDA 12.9 + GCC 13 exposes `std::tanh(float)` and `std::tanh(long double)` but no overload for `__half` or `__nv_bfloat16`. Every call to `cuda::std::<mathfn>(x)` with a half type is ambiguous.

**Fix (`b0805955`):** Added `is_half_v<T>` trait and routed all 23 unary ops and 8 binary ops through single-precision C math (e.g. `::tanhf(float(x))`) when `T` is `__half` or `__nv_bfloat16`.

```cpp
template <typename T>
static constexpr bool is_half_v =
    cuda::std::is_same_v<T, __half> || cuda::std::is_same_v<T, __nv_bfloat16>;

struct Tanh {
  template <typename T>
  __device__ T operator()(T x) {
    if constexpr (is_half_v<T>)
      return static_cast<T>(::tanhf(static_cast<float>(x)));
    else
      return cuda::std::tanh(x);
  }
};
```

**When re-applying upstream:** Check whether upstream has added `__half`/`__nv_bfloat16` math overloads. If so, the trait guard can be removed. If not, reapply to both `unary_ops.cuh` and `binary_ops.cuh`.

---

### 2 — CUTLASS exclusion (CudaBuild.json + stubs)

**Why it breaks:** The `quantized/qmm/` CUDA kernels import `cute/numeric/numeric_types.hpp` from CUTLASS. CUTLASS is not installed on this system and cannot be easily separated from the rest of the sm_90 kernel stack.

**Fix (`ed849611`, `04c6cce`):**

*CudaBuild.json* (mlx-swift) excludes these from `.cu` compilation:
```json
"mlx/mlx/backend/cuda/quantized/qmm",
"mlx/mlx/backend/cuda/quantized/fp_quantize.cu",
"mlx/mlx/backend/cuda/quantized/qqmm_utils.cu",
"mlx/mlx/backend/cuda/gemms/grouped_gemm_unaligned.cu"
```

*Package.swift* (mlx-swift) excludes from SPM source compilation:
```
mlx/mlx/backend/cuda/quantized/qqmm_impl.cpp
mlx/mlx/backend/cuda/quantized/cublas_qqmm.cpp
```

Three stub `.cpp` files (compiled by SPM, not the CUDA plugin) provide the missing link symbols and throw a descriptive `runtime_error` if reached:

- `no_qmm_impl.cpp` — stubs `supports_qmm_sm90`, `qmm_sm90`, `supports_fp_qmv`, `fp_qmv`, `supports_qmv`, `qmv`
- `no_fp_quantize_impl.cpp` — stubs `fp_quantize`, `fp_dequantize`, `swizzle_scale`
- `no_cutlass_gemm_impl.cpp` — stubs `cutlass_grouped_gemm`, `segmented_mm`

**When re-applying upstream:** If upstream adds a CUTLASS-free code path or a cmake switch, these stubs can be removed. Until then, exclude the same files. Check `qmm.h` for any new function signatures the stubs need to match.

**Gotcha:** After adding or removing stub files or changing Package.swift excludes, delete `.build/build.db` to force llbuild to re-scan sources. Without this, stale cached file lists cause multiple-definition link errors or missing symbols.

```bash
rm .build/build.db
rm -rf .build/manifest.db
```

---

### 3 — GPU fallback for affine quantized matmul on sm_86

**Why it breaks:** After excluding CUTLASS, the dispatcher in `quantized.cpp` has no path for the 4-bit affine quantized model on sm_86:
- `supports_qmm_sm90` → false (CUTLASS stub)
- `supports_fp_qmv` → false (CUTLASS stub)
- `supports_qmv` → false (CUTLASS stub)
- Dispatcher throws `[quantized_matmul] No implementation for problem shape: ...`

**This is not a CPU fallback.** The fix runs entirely on the GPU using existing cuBLAS infrastructure.

**Fix (`bc5c40dc`):** Before the final `throw` in `QuantizedMatmul::eval_gpu`, added a fallback for `mode_ == Affine && biases.has_value() && transpose_`:

1. Dequantize weights on-GPU: `affine_dequantize(w[N, K_packed] → w_dq[N, K], x.dtype())`
2. Run standard cuBLAS GEMM: `x[B*M, K] × w_dq^T[K, N] → out[B*M, N]`

The temporary `w_dq` is registered with `encoder.add_temporary()` so it is freed after the GEMM completes — one layer at a time, not all at once.

**CublasGemm dimension convention (critical):** `b_rows` and `b_cols` are **logical** dimensions — independent of `b_transposed`. `b_transposed` only describes the physical storage layout. For a weight matrix stored as `[N, K]` (physical) that we want to multiply as `[K, N]` (logical, transposed):

```cpp
CublasGemm gemm(
    encoder.device(),
    x.dtype(),
    false, M_eff, K, lda,  // a: [B*M, K] row-major, lda=K
    true,  K,    N, ldb,   // b: logical [K,N], stored [N,K], ldb=K_deq
    ...);
```

Passing physical dimensions (`N_deq`, `K_deq`) instead of logical (`K`, `N`) produces an invalid matrix descriptor and causes `cublasLtMatmulAlgoGetHeuristic` to return `CUBLAS_STATUS_NOT_SUPPORTED` (code 7) — fixed in `119de463`.

**When re-applying upstream:** If upstream adds sm_86-compatible quantized GEMM kernels (e.g. via cuBLAS directly or a cuSPARSELt path), check whether the fallback is still needed. The fallback is gated on `Affine && biases && transpose_` so it won't interfere with other quantization modes.

---

### 4 — cuDNN Frontend include path

**Why it breaks:** The CUDA attention backend (`scaled_dot_product_attention.cpp`) includes `cudnn_frontend.h`, which is not in the default compiler search path.

**Fix (`862693e`):** `setup-cuda-ubuntu.sh` clones `https://github.com/NVIDIA/cudnn-frontend v1.16.0` to `/usr/local/cudnn-frontend`. Package.swift adds:

```swift
.unsafeFlags(["-I/usr/local/cudnn-frontend/include"]),
.unsafeFlags(["-DCUDNN_FRONTEND_SKIP_JSON_LIB"]),
```

The define suppresses the nlohmann/json dependency so that package does not need to be installed separately.

**When re-applying upstream:** If upstream bundles cudnn-frontend as a submodule or adds a proper cmake find_package call, remove the manual include path. Keep `-DCUDNN_FRONTEND_SKIP_JSON_LIB` unless the build system provides nlohmann/json.

---

### 5 — clang version guard

**Fix (`971c7c8`):** Added `-allow-unsupported-compiler` to the CudaBuild plugin's nvcc invocation. Swift 6.3 ships clang 20, which CUDA 12.9's nvcc rejects as "unsupported" without this flag.

---

### 6 — LAPACK include path

`mlx/backend/cpu/lapack.h` uses `#include <lapack.h>` (angled). This resolves automatically on any machine where `liblapacke-dev` is installed (`/usr/include/lapack.h`). No patch needed beyond ensuring the package is installed.

---

### 7 — swift-transformers Linux compat

Upstream `swift-transformers` uses Darwin-only APIs throughout the Hub downloader:
- `URLSession(configuration:delegate:delegateQueue:)` with background configuration — not available on Linux
- `URLSessionDataTask.bytes` (async stream) — not available on Linux
- `autoreleasepool {}` — not available on Linux
- `String(localized:)` — not available without Foundation localisation stack on Linux
- `import os` (OSLog) — Darwin only
- `CFNumberIsFloatType` — CoreFoundation, Darwin only

Each was replaced with `#if canImport(Darwin)` guards or Linux-compatible equivalents (`FoundationNetworking`, plain `URLSession.data(from:)`, literal strings). Commits `1612797`–`56f4dd1`.

---

### 8 — mlx-swift-lm Linux compat

- `CGSize` is defined in CoreGraphics, which is Darwin-only. Added `LinuxCompat.swift` with a minimal `struct CGSize` for Linux (`c25e0bd`).
- `AVFoundation` and `CoreImage` imports guarded with `#if canImport(AVFoundation)` / `#if canImport(CoreImage)` in `UserInput.swift` and `ChatSession.swift`.

---

## Runtime issues

### R1 — Actor race: model loaded twice

**Symptom:** Two concurrent embedding requests both see `loadedContainer == nil` during the `await loadModelContainer(...)` suspension point and both start a full model load. Second load either crashes or wastes 30+ seconds.

**Root cause:** Swift actors serialise synchronous sections but suspend at `await`, allowing another caller to enter. Between the nil-check and the assignment of `loadedContainer`, any number of suspended tasks can wake up and see nil.

**Fix (`1de9e99` in Thread):** Store a `loadingTask: Task<ModelContainer, Error>?`. On first call, create the Task and save it before awaiting. Subsequent callers check `loadingTask` first and `await task.value` on the same Task — they share the result, never start a second load.

```swift
private func loadedModel(logger: Logger) async throws -> ModelContainer {
    if let c = loadedContainer { return c }
    if let t = loadingTask   { return try await t.value }
    let t = Task<ModelContainer, Error> { try await loadModelContainer(...) }
    loadingTask = t
    do {
        let c = try await t.value
        loadedContainer = c; loadingTask = nil
        return c
    } catch {
        loadingTask = nil; throw error
    }
}
```

---

### R2 — `[quantized_matmul] No implementation` at runtime

**Symptom:** Model loads successfully but the first inference request crashes with:
```
[quantized_matmul] No implementation for problem shape: 1x2048x1536x1 activation: bfloat16, bits: 4, group size: 64, mode: "affine".
```

**Root cause:** All three CUTLASS paths (`qmm_sm90`, `fp_qmv`, `qmv`) return false on sm_86. The dispatcher had no fallback and threw immediately.

**Fix:** GPU fallback in `quantized.cpp` — see Build patch 3 above.

---

### R3 — OOM with large partition batches

**Symptom:** Server crashes with GPU OOM when embedding a document with 100+ partitions.

**Root cause:** `maxInputsPerBatch = 256` sent all partitions through the model in one shot. MLX builds a lazy computation graph — the entire graph (activations × layers × dequantized weight temps) is materialised at once before a single result is read.

**Fix (Thread `MLXEmbeddingModelProvider.swift`):**
- Reduced `maxInputsPerBatch` from 256 → 16. For 150 partitions this produces ~10 sub-batches.
- Added `MLX.eval(embeddings)` after model forward pass to force synchronous GPU execution before moving to the next sub-batch. Without this, MLX defers execution and all sub-batches' graphs queue up simultaneously.
- Added `MLX.Memory.clearCache()` after reading each sub-batch's results to immediately free dequantized-weight temporaries and activation buffers before the next sub-batch's allocation.

```swift
let output     = model(padded, ...)
let embeddings = output.textEmbeds
MLX.eval(embeddings)                   // flush graph → free temporaries

for i in 0..<embeddings.shape[0] {
    allData.append(...)
}

MLX.Memory.clearCache()                // return cached GPU buffers to allocator
```

---

### R4 — SDPA cache thrashing fatal error

**Symptom:** After several sub-batches, server crashes with:
```
MLX/ErrorHandler.swift:345: Fatal error: Cache thrashing is happening,
please set the environment variable MLX_CUDA_SDPA_CACHE_SIZE to a larger
value than 256 to fix degraded performance.
```

**Root cause:** MLX's CUDA SDPA (Scaled Dot Product Attention) backend compiles a cuDNN graph for each unique attention configuration `(B, T_q, T_kv, num_heads, head_dim)`. These compiled graphs are cached in an LRU of size 256. When sequence lengths vary across sub-batches, each distinct length produces a new cache entry. After 512 misses (2× capacity), the thrashing check fires a `runtime_error` that becomes a Swift `fatalError`.

**How the cache is initialised:** `sdpa_cache()` in `scaled_dot_product_attention.cpp` is a function-local `static`. It is initialised exactly once on the first SDPA call, reading `MLX_CUDA_SDPA_CACHE_SIZE` from the environment at that moment. Once initialised, the capacity is fixed for the process lifetime.

**Fix (`4d864085` in riteshpakala/mlx):** Changed the baked-in default from 256 → 2048 directly in the C++ source:

```cpp
auto& sdpa_cache() {
  static LRUBytesKeyCache<SDPACacheKey, DnnGraph> cache(
      "MLX_CUDA_SDPA_CACHE_SIZE", /* default_capacity */ 2048);  // was 256
  return cache;
}
```

**Belt-and-suspenders (Thread `MLXEmbeddingModelProvider.init`):** Also calls `setenv("MLX_CUDA_SDPA_CACHE_SIZE", "2048", 0)` (the `0` means do not overwrite if the user set a larger value) before any MLX operation runs, so the override also works even if the fork is temporarily out of date.

**Power-of-2 sequence padding:** To further reduce the number of distinct SDPA shapes, sequence lengths within each sub-batch are padded to the next power of 2:

```swift
var maxLen = 1
while maxLen < rawMax { maxLen <<= 1 }
```

This collapses O(unique_seq_lengths) distinct shapes per document down to O(log₂(max_seq_length)) — typically 6–10 unique lengths across all sub-batches rather than one per unique token count.

**When re-applying upstream:** If upstream raises the default or exposes an API to set the cache size programmatically, remove the `setenv` call and the source patch. Keep the power-of-2 padding regardless — it reduces compilation work and improves buffer reuse.

---

### R5 — `cudaMallocAsync` OOM from deferred encoder temporary cleanup

**Symptom:** Server crashes with a true CUDA out-of-memory error — distinct from the fatal SDPA thrashing error — after a document has been successfully indexed:

```
cudaMallocAsync(&data, size, stream) failed: out of memory at
.build/checkouts/mlx-swift/Source/Cmlx/mlx-c/mlx/c/transforms.cpp:73
```

The crash is on the _next_ allocation after the previous batch's work completes, not during the batch itself.

**Root cause — encoder temporary lifecycle:**

MLX's CUDA backend uses a `CommandEncoder` that accumulates per-operation temporaries via `encoder.add_temporary(array)`. Two places in the inference path use this:

1. `quantized.cpp` GPU fallback: `w_dq` (the dequantized bfloat16 weight matrix) is a temporary.
2. `cudnn_utils.cpp` `allocate_workspace`: the cuDNN SDPA workspace is allocated as a temporary on every attention call.

`add_temporary` moves the array's data shared pointer into a completion handler lambda that is only destroyed — and the memory freed — when `CommandEncoder::commit()` is called and the handler executes. `commit()` is triggered either by the encoder's internal op-count threshold _or_ by an explicit `CommandEncoder::synchronize()` call.

`MLX.eval(embeddings)` schedules GPU work and `asArray()` waits for results, but neither is guaranteed to call `CommandEncoder::synchronize()`. As a result, the completion handlers that hold `w_dq` and the cuDNN workspace pointers accumulate across sub-batches without being processed.

**Memory accumulation estimate (Qwen3-0.6B, 28 layers):**

| Temporary per layer | Size (bf16) |
|---|---|
| Q projection [1024, 1024] | ~2 MB |
| K projection [1024, 256] | ~0.5 MB |
| V projection [1024, 256] | ~0.5 MB |
| O projection [1024, 1024] | ~2 MB |
| gate/up proj [1024, 2816] | ~5.5 MB each |
| down proj [2816, 1024] | ~5.5 MB |
| cuDNN SDPA workspace | varies |

Per forward pass: roughly 600 MB of encoder temporaries unfreed. Over 5 sub-batches (69 partitions ÷ 8 per batch = 9 passes), accumulation easily reaches several GB before the CUDA pool can no longer satisfy a new `cudaMallocAsync`.

**Fix (`MLXEmbeddingModelProvider.swift`):**

- `maxInputsPerBatch` reduced 16 → 8: halves peak activation memory per sub-batch.
- `maxTokensPerSequence = 512` with `.prefix()` truncation: caps the attention matrix at 512² instead of unbounded. A 1024-token sequence produces 4× the attention memory of a 512-token sequence; beyond 512 tokens embedding quality for retrieval is largely unchanged.
- Aggressive cache flush at **document boundaries** (after all sub-batches complete): temporarily set `cacheLimit = 0`, call `clearCache()`, then restore to 20 MB. This ensures the CUDA async pool can reclaim all buffers between documents without waiting for MLX's normal cache-eviction heuristic.

```swift
// Per sub-batch — keep mid-inference overhead low
MLX.Memory.clearCache()

// End of document — return everything before the next request allocates
MLX.Memory.cacheLimit = 0
MLX.Memory.clearCache()
MLX.Memory.cacheLimit = 20 * 1_024 * 1_024
```

**SIGSEGV trap — do NOT call any `MLX.Memory.*` or `Stream.*` APIs from within `container.perform`:**

Two attempts were made to force cleanup from inside the inference closure:

1. `Stream.defaultStream(.gpu).synchronize()` → SIGSEGV at `cudaGraphLaunch` inside `commit()` (graph already launched, re-launching with stale `CudaGraphExec` from the cache)
2. `MLX.Memory.clearCache()` and `MLX.Memory.cacheLimit = 0` inside the closure → SIGSEGV at a tiny address (`0x6529`) — classic null-pointer-plus-offset pattern indicating a corrupted object pointer inside the CUDA allocator

Root cause in both cases: `container.perform` runs on MLX's evaluation thread. The `CommandEncoder` is actively managing CUDA graph state and the allocator's internal mutex and cache are in mid-use. Any call that re-enters `evalLock`, `mlx_clear_cache`, `mlx_set_cache_limit`, or `CommandEncoder::synchronize()` from that thread context either deadlocks or corrupts internal state.

**The rule**: `container.perform` is a pure inference zone. Call the model, eval, read results, return. Nothing else.

All memory management happens **after `container.perform` returns**, when the CUDA context is idle:

```swift
let result = await container.perform { model, tokenizer in
    // inference only — no MLX.Memory.* here
    return (allData, usage)
}

// Safe: CUDA context is idle, allocator is not locked
MLX.Memory.cacheLimit = 0
MLX.Memory.clearCache()
MLX.Memory.cacheLimit = 20 * 1_024 * 1_024

return result
```

**When re-applying upstream:** If upstream changes the eval path so that completion handlers are processed synchronously during `eval()`, the `cacheLimit = 0` flush becomes redundant (safe to keep, just wastes one round-trip). Keep `maxTokensPerSequence` regardless — it provides a hard bound on attention memory independent of temporary lifecycle.

---

## Syncing forks with upstream

When `ml-explore/mlx` or `ml-explore/mlx-swift` cut a new release, the process is:

1. **Fetch upstream into the fork:**
   ```bash
   cd .build/checkouts/mlx-swift/Source/Cmlx/mlx
   git fetch origin          # upstream ml-explore/mlx
   git checkout gab/cuda1
   git rebase origin/main    # or merge — resolve conflicts per patch below
   git push riteshpakala gab/cuda1
   ```

2. **Re-apply or verify each patch** (check if upstream fixed it natively):

   | Patch | File(s) | Re-apply if... |
   |---|---|---|
   | Half-precision math | `unary_ops.cuh`, `binary_ops.cuh` | Upstream still has no `__half` math overloads |
   | CUTLASS stubs | `no_qmm_impl.cpp`, `no_fp_quantize_impl.cpp`, `no_cutlass_gemm_impl.cpp` | CUTLASS still not bundled/optional |
   | GPU affine fallback | `quantized.cpp` | No cuBLAS path for sm_86 affine 4-bit matmul |
   | SDPA cache default | `scaled_dot_product_attention.cpp` | Default still 256 |
   | lapack.h path | `lapack.h` | No change needed (angled include works with liblapacke-dev) |

3. **Bump the mlx-swift submodule** to the new mlx gab/cuda1 tip:
   ```bash
   cd .build/checkouts/mlx-swift
   git checkout gab/cuda1
   git add Source/Cmlx/mlx
   git commit -m "Bump mlx submodule to <hash>"
   git push github gab/cuda1
   ```
   Note: the mlx-swift checkout is in detached HEAD state when SPM manages it. Push with `git push github HEAD:gab/cuda1`.

4. **Verify CudaBuild.json excludes** still match the file structure in the new upstream version — new CUTLASS-dependent `.cu` files may have been added.

5. **Delete build.db and rebuild:**
   ```bash
   rm .build/build.db .build/manifest.db 2>/dev/null
   SPM_CUDA=1 CUDA_ARCH=sm_86 swift build -c debug --jobs 2
   ```

---

## Troubleshooting index

| Error | Cause | Fix |
|---|---|---|
| `__grid_constant__ annotation is only allowed for compute_70 or later` | `CUDA_ARCH` not set | `export CUDA_ARCH=sm_86` |
| `'lapack.h' file not found` | `liblapacke-dev` not installed | `sudo apt install liblapacke-dev` |
| `'cudnn_frontend.h' file not found` | cudnn-frontend not cloned | `git clone https://github.com/NVIDIA/cudnn-frontend /usr/local/cudnn-frontend` |
| `'cute/numeric/numeric_types.hpp' file not found` | CUTLASS file not excluded (stale build.db) | `rm .build/build.db && rebuild` |
| `multiple definition of qmv` | Stale build.db includes both real and stub | `rm .build/build.db && rebuild` |
| `Ambiguous call to cuda::std::tanh` | Half-precision patch not in checkout | `rm -rf .build/checkouts/mlx-swift && swift package resolve` |
| `[quantized_matmul] No implementation for problem shape` | GPU fallback missing from quantized.cpp | Verify `bc5c40dc` is in mlx gab/cuda1 |
| `cublasLtMatmulAlgoGetHeuristic` code 7 | b_rows/b_cols passed as physical not logical | Verify `119de463` is in mlx gab/cuda1 |
| `Cache thrashing is happening` fatal error | SDPA cache too small for varying seq lengths | Verify `4d864085` in mlx gab/cuda1; rebuild |
| GPU OOM on large documents | Batch too large, sequences too long, or missing end-of-document cache flush | `maxInputsPerBatch=8`, `maxTokensPerSequence=512`, `cacheLimit=0`+`clearCache()` after all sub-batches |
| SIGSEGV in `cudaGraphLaunch` inside `commit()` | Called `Stream.synchronize()` from within `container.perform` — re-enters encoder while graph is mid-launch | Remove all `Stream.*` and `MLX.Memory.*` calls from inside `container.perform` |
| SIGSEGV at tiny address (`0x6529`) in CommandEncoder | Called `MLX.Memory.clearCache()` or `cacheLimit = 0` from inside `container.perform` — corrupts CUDA allocator internal state | Same: move ALL memory management to after `container.perform` returns |
| Model loaded twice / double-load race | Actor nil-check race at await | Verify `loadingTask` pattern in `MLXEmbeddingModelProvider` |
