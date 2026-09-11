//
//  Sinatra.Adjustment.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 2/16/26.
//

import Foundation

struct SinatraAdjustment {
    /// Per-partition record of a single GBT distance adjustment.
    /// Codable so it can be stored in `SinatraRegistry.lastSearchEntries`.
    struct Entry: Codable {
        let partitionId: String
        let originalDistance: Float
        let adjustedDistance: Float
        /// The effective threshold that determines whether a partition is kept.
        let threshold: Float

        /// Partition was filtered out because its adjusted distance exceeded threshold.
        var wasDropped: Bool { adjustedDistance >= threshold }

        /// `adjustedDistance / originalDistance`.
        /// < 1.0 = boosted, > 1.0 = demoted, == 1.0 = no model applied.
        var factor: Float { originalDistance > 0 ? adjustedDistance / originalDistance : 1.0 }

        enum Status: String, Codable {
            case boosted    // factor < 0.98  — moved closer, higher rank
            case unchanged  // factor ≈ 1.0   — no effective change
            case demoted    // factor > 1.02  — moved further, lower rank
            case dropped    // adjustedDistance ≥ threshold — removed from results
        }

        var status: Status {
            if wasDropped  { return .dropped }
            if factor < 0.98 { return .boosted }
            if factor > 1.02 { return .demoted }
            return .unchanged
        }

        enum CodingKeys: String, CodingKey {
            case partitionId      = "partition_id"
            case originalDistance = "original_distance"
            case adjustedDistance = "adjusted_distance"
            case threshold
        }
    }

    let partitionCount: Int
    let original: [String]
    let inferred: [String]
    let pqDistanceThreshold: Float
    /// Per-partition detail — empty when inference was not applied.
    var entries: [Entry]

    init(
        partitionCount: Int,
        original: [String],
        inferred: [String],
        pqDistanceThreshold: Float,
        entries: [Entry] = []
    ) {
        self.partitionCount     = partitionCount
        self.original           = original
        self.inferred           = inferred
        self.pqDistanceThreshold = pqDistanceThreshold
        self.entries            = entries
    }
}
