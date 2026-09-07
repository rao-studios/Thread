//
//  Database.DocumentStats.swift
//  database-server
//
//  Created by Ritesh Pakala on 4/12/26.
//

import Foundation

extension Database {
    /// Billing and engagement statistics for a single document.
    ///
    /// `DocumentStats` is decoupled from `Database.Document` so the core document model
    /// stays lean. Stats are keyed by the same `DocumentID` and stored in
    /// `ThreadRegistry.documentStats`, following the same registration, removal,
    /// and access flows as the document itself.
    ///
    /// Performance fields (`retrievalCount`, `sentimentSum`, `lastRetrieved`) were
    /// previously tracked as `DocumentPerformance` inside `RetrievalDataCollector`.
    /// They now live here so all per-document state is in one place.
    struct DocumentStats: Codable {

        // MARK: - Per-Partition Sentiment

        /// Cumulative sentiment accumulator for a single content-addressed partition.
        ///
        /// Because partition IDs are SHA-256 hashes of their embedding vector, the
        /// same "thought" (identical content, same embedding model) always maps to
        /// the same `PartitionSentiment` entry. The GBT feature vector reads
        /// `averageSentiment` from this entry so inference reflects how strongly
        /// the user has engaged with this specific content unit over time.
        struct PartitionSentiment: Codable {
            var retrievalCount: Int  = 0
            var sentimentSum: Double = 0.0
            var lastRetrieved: Date? = nil

            /// Running average sentiment [0, 1].
            /// Returns 0.5 (neutral prior) when no interactions have been recorded.
            var averageSentiment: Double {
                retrievalCount > 0 ? sentimentSum / Double(retrievalCount) : 0.5
            }

            enum CodingKeys: String, CodingKey {
                case retrievalCount = "retrieval_count"
                case sentimentSum   = "sentiment_sum"
                case lastRetrieved  = "last_retrieved"
            }

            init() {}

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                retrievalCount = try c.decodeIfPresent(Int.self,    forKey: .retrievalCount) ?? 0
                sentimentSum   = try c.decodeIfPresent(Double.self, forKey: .sentimentSum)   ?? 0.0
                lastRetrieved  = try c.decodeIfPresent(Date.self,   forKey: .lastRetrieved)
            }
        }

        // MARK: - Document Fields

        /// The document this record belongs to.
        var id: DocumentID

        /// Cumulative credits earned by this document across all inferences
        /// in which at least one of its partitions was retrieved and priced.
        ///
        /// Updated atomically through `RegistryMutator.accumulateEarnings(_:)`
        /// whenever a `Gita.Contribution` with non-zero payouts is finalized.
        var totalEarned: Gita.Credits

        // MARK: - Performance (formerly DocumentPerformance)

        /// Number of times any partition of this document was retrieved and scored.
        var retrievalCount: Int

        /// Sum of all effective sentiment weights recorded across this document's partitions.
        /// Divide by `retrievalCount` to get the running average.
        var sentimentSum: Double

        /// Timestamp of the most recent retrieval of any partition in this document.
        var lastRetrieved: Date?

        /// Running average sentiment weight across all partitions.
        /// Returns 0.5 (neutral prior) when no retrievals have been recorded yet.
        var averageSentiment: Double {
            retrievalCount > 0 ? sentimentSum / Double(retrievalCount) : 0.5
        }

        // MARK: - Per-Partition Analytics

        /// How many times each individual partition was retrieved.
        /// Key is the partition's content-addressed ID (SHA-256 hash of its embedding).
        /// Populated by `RegistryMutator.accumulatePerformance` after each Sinatra
        /// `prepare` cycle. Useful for identifying hot vs. cold partitions within a document.
        var partitionRetrievalCount: [String: Int]

        /// Per-partition sentiment accumulators.
        /// Key is the partition's content-addressed ID.
        /// The GBT feature vector reads `partitionSentiments[partitionId].averageSentiment`
        /// so that inference reflects the user's engagement with a specific "thought" unit,
        /// not just the document as a whole.
        var partitionSentiments: [String: PartitionSentiment]

        init(
            id: DocumentID,
            totalEarned: Gita.Credits = 0,
            retrievalCount: Int = 0,
            sentimentSum: Double = 0.0,
            lastRetrieved: Date? = nil,
            partitionRetrievalCount: [String: Int] = [:],
            partitionSentiments: [String: PartitionSentiment] = [:]
        ) {
            self.id = id
            self.totalEarned = totalEarned
            self.retrievalCount = retrievalCount
            self.sentimentSum = sentimentSum
            self.lastRetrieved = lastRetrieved
            self.partitionRetrievalCount = partitionRetrievalCount
            self.partitionSentiments = partitionSentiments
        }

        enum CodingKeys: String, CodingKey {
            case id
            case totalEarned             = "total_earned"
            case retrievalCount          = "retrieval_count"
            case sentimentSum            = "sentiment_sum"
            case lastRetrieved           = "last_retrieved"
            case partitionRetrievalCount = "partition_retrieval_count"
            case partitionSentiments     = "partition_sentiments"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id                      = try c.decode(DocumentID.self, forKey: .id)
            totalEarned             = try c.decodeIfPresent(Gita.Credits.self,                   forKey: .totalEarned)             ?? 0
            retrievalCount          = try c.decodeIfPresent(Int.self,                            forKey: .retrievalCount)          ?? 0
            sentimentSum            = try c.decodeIfPresent(Double.self,                         forKey: .sentimentSum)            ?? 0.0
            lastRetrieved           = try c.decodeIfPresent(Date.self,                           forKey: .lastRetrieved)
            partitionRetrievalCount = try c.decodeIfPresent([String: Int].self,                  forKey: .partitionRetrievalCount) ?? [:]
            partitionSentiments     = try c.decodeIfPresent([String: PartitionSentiment].self,   forKey: .partitionSentiments)     ?? [:]
        }
    }
}
