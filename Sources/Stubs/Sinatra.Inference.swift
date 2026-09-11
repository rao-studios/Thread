//
//  Sinatra.Inference.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 1/25/26.
//

import Foundation

struct SinatraInference {
    /// The partition id being evaluated during search.
    var partitionId: String
    /// The document this partition belongs to.
    /// Used to look up the correct `DocumentStats` entry during feature vector generation.
    /// Defaults to `""` for call sites that only have a partition ID.
    var documentId: String = ""
    /// The PQ distance computed for the current query against this partition.
    var distance: Float

    struct Result {
        /// The adjusted distance after SVM prediction.
        var adjustedDistance: Float
        /// Whether inference was applied (model was trained with enough data).
        var applied: Bool

        static func unadjusted(distance: Float) -> Result {
            .init(adjustedDistance: distance, applied: false)
        }
    }
}
