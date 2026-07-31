import Foundation
import Logging

/// Minimal Sinatra stub for Totem — all methods return identity (no adjustment).
/// The full GBT/SVM ranking engine is not included; distances pass through unchanged.
class Sinatra: @unchecked Sendable {
    internal let logger: TotemLogger

    nonisolated(unsafe) static var sentimentContextLimit: Int = 4
    static let maxParkedEntries: Int = 30

    init(logger: Logger) {
        self.logger = TotemLogger(logger)
    }

    var registry: SinatraRegistry? { nil }

    func infer(
        _ inference: SinatraInference,
        registry: SinatraRegistry?,
        documentStats: [DocumentID: Database.DocumentStats] = [:],
        request: DatabaseRequest
    ) -> SinatraInference.Result {
        .unadjusted(distance: inference.distance)
    }

    // Parking data is used for Self-RLHF. Not featured in the Mini.
    func park(
        data: [(score: Float, partition: Database.Partition)],
        forQuery: [Float],
        request: DatabaseRequest
    ) {}

}

/// Empty stub — SinatraRegistry is passed to Sinatra methods but never inspected
/// since all stub methods return immediately without reading it.
struct SinatraRegistry {}
