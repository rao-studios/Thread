//
//  ProductQuantizer.swift
//  database-server
//
//  Created by Ritesh Pakala on 11/13/25.
//

// IMPORTANT: Needs refinement towards a standardization into a semantic codec.
// A real write-up behind the embedding compression process.
// Since it is lossy, we need to monitor what gets lost in the compression
// process and how it affects search recall. The winning codec drives the
// industry.

// Split 1024-dim vector into 16 chunks of 64 dims
// Create codebook for each chunk (size scaled dynamically at train time)
// Result: 16 small LUTs instead of one impossible LUT

import Foundation
import MLX
import MLXAccelerate

/*
 // Option 1: Finer granularity (better accuracy, slower)  — 1024-dim input
 let numSubvectors = 32  // 32 × 32 = 1024
 let codebookSize = 256  // 64 bytes per document (2 bytes × 32 with UInt16)

 // Option 2: Coarser (faster, less accurate)  — 1024-dim input
 let numSubvectors = 8   // 8 × 128 = 1024
 let codebookSize = 256  // 16 bytes per document (2 bytes × 8 with UInt16)

 // Option 3: Default (calibrated)  — 1024-dim input
 let numSubvectors = 16  // 16 × 64 = 1024
 let codebookSize = 65536  // 32 bytes per document (2 bytes × 16 with UInt16)
*/
struct PartitionQuantizer: Codable {
    var numSubvectors = 16  // Split 1024-dim vector into 16 × 64-dim chunks
    var codebookSize = 65536 // Actual value set dynamically during train(); UInt16 ceiling
    var codebooks: [[[Float]]] = []  // numSubvectors codebooks, codebookSize entries each

    /// Per-subvector codebooks flattened to one contiguous buffer each
    /// (`flatCodebooks[i].count == codebooks[i].count * subDim`). Derived from
    /// `codebooks` after train()/decode — never persisted, so the on-disk plist
    /// format is unchanged.
    var flatCodebooks: [[Float]] = []

    /// Hard ceiling for codebook size. UInt16 encodes up to 65536 centroid indices.
    static let maxCodebookSize: Int = 65536

    /// Minimum codebook size. Below 2 all documents share one centroid — no discrimination.
    static let minCodebookSize: Int = 2

    /// Faiss rule of thumb: at least this many training vectors per centroid for
    /// stable k-means convergence. Used by `scaledCodebookSize(for:)`.
    static let vectorsPerCentroid: Int = 39

    /// Computes the largest power-of-two codebook size that satisfies the
    /// `vectorsPerCentroid` density requirement, clamped to [minCodebookSize, maxCodebookSize].
    /// This lets small per-document indices use k=2–16 while a large global index
    /// can grow all the way to k=65536 as the corpus expands.
    static func scaledCodebookSize(for vectorCount: Int) -> Int {
        let ideal = vectorCount / vectorsPerCentroid
        guard ideal >= minCodebookSize else { return minCodebookSize }
        // Round down to nearest power of two so codebook entries stay aligned.
        var k = 1
        while k * 2 <= ideal && k * 2 <= maxCodebookSize { k *= 2 }
        return k
    }

    /// Calibrated per-subvector distance baseline derived from empirical benchmarks.
    /// Current reference codec: numSubvectors=16, 1024-dim input, codebookSize=65536, UInt16.
    /// When switching to a new codec, re-run held-out retrieval benchmarks and update
    /// this value — both `distanceThreshold` and `defaultDistanceThreshold` will
    /// then reflect the new calibration everywhere (PartitionIndex and Oracle).
    /// Calibrated for 1024-dim Mistral embeddings, 16 subvectors × 64-dim each, codebookSize=65536.
    /// `adaptiveThreshold` (computed per-partition from reconstruction errors during train())
    /// overrides this for trained indices — this is the static fallback only.
    static let calibratedThresholdPerSubvector: Float = 8.0 / 16  // ≈ 0.5 — 1024-dim Mistral

    /// Default numSubvectors used by this codec. Mirrors the stored-property default
    /// so that `defaultDistanceThreshold` can be computed without an instance.
    static let defaultNumSubvectors: Int = 16

    /// Canonical distance threshold for the default codec configuration.
    /// Use this wherever a compile-time constant is needed (e.g. Oracle defaults).
    /// Per-instance threshold is `distanceThreshold`, which adapts when `numSubvectors` changes.
    static let defaultDistanceThreshold: Float = calibratedThresholdPerSubvector * Float(defaultNumSubvectors)

    /// Aggregate PQ distance threshold for this codec configuration.
    /// Scales linearly with `numSubvectors` so the cutoff stays valid when the codec
    /// is re-parameterised. Not persisted — always derived from the current codec config.
    var distanceThreshold: Float {
        Float(numSubvectors) * Self.calibratedThresholdPerSubvector
    }

    /// Per-partition threshold derived from reconstruction errors of the training vectors.
    /// Nil for indexes trained before adaptive calibration was introduced — use `effectiveThreshold`.
    var adaptiveThreshold: Float? = nil

    /// The threshold to use during search. Prefers the adaptive per-partition value;
    /// falls back to the global codec calibration for legacy indexes.
    var effectiveThreshold: Float {
        adaptiveThreshold ?? distanceThreshold
    }

    // MARK: - Codable
    // `flatCodebooks` is derived and excluded; everything else mirrors the
    // previously synthesized coding so existing persisted indices load unchanged.

    enum CodingKeys: String, CodingKey {
        case numSubvectors
        case codebookSize
        case codebooks
        case adaptiveThreshold
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        numSubvectors = try container.decode(Int.self, forKey: .numSubvectors)
        codebookSize = try container.decode(Int.self, forKey: .codebookSize)
        codebooks = try container.decode([[[Float]]].self, forKey: .codebooks)
        adaptiveThreshold = try container.decodeIfPresent(Float.self, forKey: .adaptiveThreshold)
        rebuildFlatCodebooks()
    }

    private mutating func rebuildFlatCodebooks() {
        flatCodebooks = codebooks.map { codebook in
            var flat = [Float]()
            flat.reserveCapacity(codebook.count * (codebook.first?.count ?? 0))
            for centroid in codebook { flat.append(contentsOf: centroid) }
            return flat
        }
    }

    // MARK: - MLX gating

    /// Batched MLX k-means runs on the GPU on Linux (CUDA build). On Darwin the
    /// vendored MLX cannot initialize (no metallib — any MLXArray creation
    /// aborts), so the CPU kernels are always used there.
    /// Override with `THREAD_PQ_MLX=1|0`.
    static let mlxTrainEnabled: Bool = {
        switch ProcessInfo.processInfo.environment["THREAD_PQ_MLX"] {
        case "1": return true
        case "0": return false
        default:
            #if os(Linux)
            return true
            #else
            return false
            #endif
        }
    }()

    /// Minimum `vectorCount × codebookSize` before the MLX path is worth its
    /// dispatch/transfer overhead; below this the CPU kernels win.
    /// Override with `THREAD_PQ_MLX_MIN_VK`.
    static let mlxMinVectorCentroidProduct: Int = {
        ProcessInfo.processInfo.environment["THREAD_PQ_MLX_MIN_VK"].flatMap(Int.init) ?? 4096
    }()

    // MARK: - Train

    /// Builds LUTs from document/partition vectors and returns each training
    /// vector's PQ codes (callers reuse these instead of re-encoding).
    /// Also calibrates `adaptiveThreshold` from the reconstruction errors
    /// captured during the same pass.
    /// - Parameter vectors: The partition embedding vectors.
    @discardableResult
    mutating func train(vectors: [[Float]]) -> [[UInt16]] {
        guard !vectors.isEmpty else { return [] }
        let subvectorDim = vectors[0].count / numSubvectors

        // Scale codebook size to the training corpus so k-means is always well-populated.
        // Small per-doc indices (e.g. a social post with 3 partitions) get k=2;
        // a global index with 100k partitions grows to k=2048 or higher.
        codebookSize = Self.scaledCodebookSize(for: vectors.count)
        codebooks.removeAll(keepingCapacity: true)

        let useMLX = Self.mlxTrainEnabled
            && vectors.count >= codebookSize
            && vectors.count * codebookSize >= Self.mlxMinVectorCentroidProduct

        if useMLX {
            return trainMLX(vectors, subvectorDim: subvectorDim)
        }
        return trainCPU(vectors, subvectorDim: subvectorDim)
    }

    /// All 16 subvector codebooks trained in one batched MLX dispatch per
    /// k-means iteration (GPU on Linux/CUDA).
    private mutating func trainMLX(_ vectors: [[Float]], subvectorDim: Int) -> [[UInt16]] {
        let s = numSubvectors, v = vectors.count, d = subvectorDim, k = codebookSize

        // (s, v, d): subvector i of vector n at [i, n, :].
        var flat = [Float](repeating: 0, count: s * v * d)
        for n in 0..<v {
            vectors[n].withUnsafeBufferPointer { src in
                flat.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<s {
                        let srcBase = i * d
                        let dstBase = (i * v + n) * d
                        for j in 0..<d { dst[dstBase + j] = src[srcBase + j] }
                    }
                }
            }
        }

        let data = MLXArray(flat, [s, v, d])
        let (centroids, codes, squaredDistances) = MLXAccelerate.kmeans(data, k: k)

        let cents = centroids.asArray(Float.self)                 // s*k*d
        codebooks = (0..<s).map { i in
            (0..<k).map { j in Array(cents[(i * k + j) * d ..< (i * k + j + 1) * d]) }
        }
        rebuildFlatCodebooks()

        let codesOut = codes.asArray(Int32.self)                  // s*v
        let d2Out = squaredDistances.asArray(Float.self)          // s*v
        var result = [[UInt16]](repeating: [UInt16](repeating: 0, count: s), count: v)
        var errors = [Float](repeating: 0, count: v)
        for i in 0..<s {
            for n in 0..<v {
                result[n][i] = UInt16(codesOut[i * v + n])
                errors[n] += sqrt(d2Out[i * v + n])
            }
        }
        calibrateAdaptiveThreshold(errors: errors)
        return result
    }

    /// CPU path: per-subvector k-means over contiguous buffers using the shared
    /// `squaredEuclidean` kernel; codes and reconstruction errors captured in a
    /// single final pass (no separate encode/distance-table passes).
    private mutating func trainCPU(_ vectors: [[Float]], subvectorDim: Int) -> [[UInt16]] {
        let s = numSubvectors, v = vectors.count, d = subvectorDim

        for i in 0..<s {
            // Contiguous (v × d) matrix for this subvector.
            var sub = [Float]()
            sub.reserveCapacity(v * d)
            let start = i * d
            for vec in vectors { sub.append(contentsOf: vec[start ..< start + d]) }

            let codebook = Self.kmeansCPU(sub, count: v, dim: d, k: codebookSize)
            codebooks.append(codebook)
        }
        rebuildFlatCodebooks()

        // Single pass: per-vector codes + per-subvector reconstruction distances.
        var result = [[UInt16]](repeating: [], count: v)
        var errors = [Float](repeating: 0, count: v)
        for n in 0..<v {
            var codes = [UInt16]()
            codes.reserveCapacity(s)
            vectors[n].withUnsafeBufferPointer { vec in
                for i in 0..<s {
                    let (code, minD2) = nearestCode(vec.baseAddress! + i * d, subvector: i, dim: d)
                    codes.append(UInt16(code))
                    errors[n] += sqrt(minD2)
                }
            }
            result[n] = codes
        }
        calibrateAdaptiveThreshold(errors: errors)
        return result
    }

    /// Calibrate an adaptive threshold from the reconstruction errors of the
    /// training vectors. Each vector's error is the distance back to its
    /// centroid representation. The distribution of these errors reflects the
    /// geometry of this specific partition's codebook:
    /// tight semantic clusters → low errors → tight threshold;
    /// broad/noisy content → high errors → looser threshold.
    private mutating func calibrateAdaptiveThreshold(errors: [Float]) {
        guard !errors.isEmpty else { return }
        let mean = errors.reduce(0, +) / Float(errors.count)
        let variance = errors.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(errors.count)
        adaptiveThreshold = max(mean + 1.5 * sqrt(variance), distanceThreshold)
    }

    /// Nearest centroid of `codebooks[subvector]` for a `dim`-length query chunk.
    @inline(__always)
    private func nearestCode(_ query: UnsafePointer<Float>, subvector: Int, dim: Int) -> (code: Int, squaredDistance: Float) {
        var minDist = Float.infinity
        var bestCode = 0
        if subvector < flatCodebooks.count, !flatCodebooks[subvector].isEmpty {
            let count = flatCodebooks[subvector].count / dim
            flatCodebooks[subvector].withUnsafeBufferPointer { flat in
                let base = flat.baseAddress!
                for j in 0..<count {
                    let dist = squaredEuclidean(query, base + j * dim, dim)
                    if dist < minDist {
                        minDist = dist
                        bestCode = j
                    }
                }
            }
        } else {
            // Defensive fallback for instances whose flat buffers were not rebuilt.
            for j in 0..<codebooks[subvector].count {
                let dist = codebooks[subvector][j].withUnsafeBufferPointer { c in
                    squaredEuclidean(query, c.baseAddress!, dim)
                }
                if dist < minDist {
                    minDist = dist
                    bestCode = j
                }
            }
        }
        return (bestCode, minDist)
    }

    // MARK: - Encode

    /// Compressing a vector to `UInt16` codes (one per subvector).
    /// UInt16 supports codebook sizes up to 65536, matching `codebookSize`.
    /// - Parameter vector: The embedding vector.
    /// - Returns: The compressed vector as codebook indices.
    func encode(vector: [Float]) -> [UInt16] {
        var codes: [UInt16] = []
        codes.reserveCapacity(numSubvectors)
        let subvectorDim = vector.count / numSubvectors

        vector.withUnsafeBufferPointer { vec in
            for i in 0..<numSubvectors {
                let (code, _) = nearestCode(vec.baseAddress! + i * subvectorDim, subvector: i, dim: subvectorDim)
                codes.append(UInt16(code))
            }
        }
        return codes
    }

    // MARK: - ADC

    /// Build a per-query distance table for Asymmetric Distance Computation (ADC).
    ///
    /// `table[i][j]` = distance from the query's i-th subvector to codebook[i]'s j-th centroid.
    /// Call once per query; pass the result to `computeDistance(table:documentCodes:)`.
    /// Cost: O(numSubvectors × codebookSize × subvectorDim) — amortised across all partitions.
    func buildDistanceTable(queryVector: [Float]) -> [[Float]] {
        let subvectorDim = queryVector.count / numSubvectors
        var table: [[Float]] = []
        table.reserveCapacity(numSubvectors)

        queryVector.withUnsafeBufferPointer { vec in
            let queryBase = vec.baseAddress!
            for i in 0..<numSubvectors {
                let numCentroids = codebooks[i].count
                var row = [Float](repeating: 0, count: numCentroids)
                if i < flatCodebooks.count, flatCodebooks[i].count == numCentroids * subvectorDim {
                    flatCodebooks[i].withUnsafeBufferPointer { flat in
                        let base = flat.baseAddress!
                        for j in 0..<numCentroids {
                            row[j] = sqrt(squaredEuclidean(queryBase + i * subvectorDim, base + j * subvectorDim, subvectorDim))
                        }
                    }
                } else {
                    for j in 0..<numCentroids {
                        row[j] = codebooks[i][j].withUnsafeBufferPointer { c in
                            sqrt(squaredEuclidean(queryBase + i * subvectorDim, c.baseAddress!, subvectorDim))
                        }
                    }
                }
                table.append(row)
            }
        }
        return table
    }

    /// O(numSubvectors) distance lookup using a precomputed ADC distance table.
    /// Each partition costs exactly `numSubvectors` array reads and additions.
    /// - Parameters:
    ///   - table: Distance table built by `buildDistanceTable(queryVector:)`.
    ///   - documentCodes: The compressed partition codes.
    /// - Returns: The approximate distance to the query.
    func computeDistance(table: [[Float]], documentCodes: [UInt16]) -> Float {
        var dist: Float = 0
        for i in 0..<numSubvectors {
            dist += table[i][Int(documentCodes[i])]
        }
        return dist
    }

    /// Compute distance between a query vector and compressed document codes.
    /// For search, prefer `buildDistanceTable` + `computeDistance(table:documentCodes:)`.
    func computeDistance(queryVector: [Float], documentCodes: [UInt16]) -> Float {
        let table = buildDistanceTable(queryVector: queryVector)
        return computeDistance(table: table, documentCodes: documentCodes)
    }
}

// MARK: - CPU K-Means

private extension PartitionQuantizer {
    /// K-means over a contiguous (count × dim) matrix. Returns nested centroid
    /// arrays (the persisted codebook layout). All distance comparisons use
    /// squared distances (identical argmin, no sqrt in the hot loops).
    static func kmeansCPU(_ data: [Float], count: Int, dim: Int, k: Int, maxIterations: Int = 20) -> [[Float]] {
        guard count > 0 else { return [] }
        guard count >= k else {
            // If fewer vectors than k, just return the vectors themselves.
            return (0..<count).map { Array(data[$0 * dim ..< ($0 + 1) * dim]) }
        }

        var centroids = kMeansPlusPlusInit(data, count: count, dim: dim, k: k)  // flat k*dim
        var assignments = [Int](repeating: 0, count: count)

        data.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!

            for _ in 0..<maxIterations {
                // Assign each vector to its nearest centroid (squared distance argmin).
                centroids.withUnsafeBufferPointer { cbuf in
                    let cbase = cbuf.baseAddress!
                    for n in 0..<count {
                        var minDist = Float.infinity
                        var best = 0
                        for j in 0..<k {
                            let dist = squaredEuclidean(base + n * dim, cbase + j * dim, dim)
                            if dist < minDist {
                                minDist = dist
                                best = j
                            }
                        }
                        assignments[n] = best
                    }
                }

                // Update centroids as mean of assigned vectors.
                var newCentroids = [Float](repeating: 0, count: k * dim)
                var counts = [Int](repeating: 0, count: k)
                for n in 0..<count {
                    let a = assignments[n]
                    counts[a] += 1
                    let cBase = a * dim, vBase = n * dim
                    for j in 0..<dim { newCentroids[cBase + j] += base[vBase + j] }
                }
                for j in 0..<k {
                    if counts[j] > 0 {
                        let inv = 1 / Float(counts[j])
                        for t in 0..<dim { newCentroids[j * dim + t] *= inv }
                    } else {
                        // Empty cluster — reinitialize with a random vector.
                        let r = Int.random(in: 0..<count)
                        for t in 0..<dim { newCentroids[j * dim + t] = base[r * dim + t] }
                    }
                }

                // Convergence: max squared centroid shift below (0.001)².
                var maxShift2: Float = 0
                centroids.withUnsafeBufferPointer { old in
                    newCentroids.withUnsafeBufferPointer { new in
                        for j in 0..<k {
                            let shift2 = squaredEuclidean(old.baseAddress! + j * dim, new.baseAddress! + j * dim, dim)
                            maxShift2 = max(maxShift2, shift2)
                        }
                    }
                }

                centroids = newCentroids

                if maxShift2 < 1e-6 {
                    break  // Converged <3
                }
            }
        }

        return (0..<k).map { Array(centroids[$0 * dim ..< ($0 + 1) * dim]) }
    }

    /// K-means++ initialization over a flat matrix. Tracks each vector's
    /// minimum *squared* distance incrementally — only the newest centroid is
    /// compared per round (O(count) per seed instead of O(count × seeds)), and
    /// the D² sampling distribution is used directly without the historical
    /// sqrt-then-resquare round trip.
    static func kMeansPlusPlusInit(_ data: [Float], count: Int, dim: Int, k: Int) -> [Float] {
        var centroids = [Float]()
        centroids.reserveCapacity(k * dim)

        data.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!

            // First centroid: random vector.
            let first = Int.random(in: 0..<count)
            centroids.append(contentsOf: data[first * dim ..< (first + 1) * dim])

            var minSqDist = [Float](repeating: .infinity, count: count)

            for round in 1..<k {
                // Fold in distances to the newest centroid only.
                let newestBase = (round - 1) * dim
                centroids.withUnsafeBufferPointer { cbuf in
                    let newest = cbuf.baseAddress! + newestBase
                    for n in 0..<count {
                        let d2 = squaredEuclidean(base + n * dim, newest, dim)
                        if d2 < minSqDist[n] { minSqDist[n] = d2 }
                    }
                }

                // Sample the next centroid with probability proportional to D².
                let totalDist = minSqDist.reduce(0, +)
                var chosen = Int.random(in: 0..<count)
                if totalDist > 0 {
                    let target = Float.random(in: 0..<totalDist)
                    var cumulative: Float = 0
                    for (idx, sqDist) in minSqDist.enumerated() {
                        cumulative += sqDist
                        if cumulative >= target {
                            chosen = idx
                            break
                        }
                    }
                }
                centroids.append(contentsOf: data[chosen * dim ..< (chosen + 1) * dim])
            }
        }

        return centroids
    }
}
