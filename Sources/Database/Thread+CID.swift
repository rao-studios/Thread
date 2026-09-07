import Foundation

extension Database {
    /// Produces a globally unique CID for a partition by prepending this Thread's
    /// persistent node UUID to the local content-addressed hash.
    ///
    /// Format: "{threadUUID}-{localHash}"
    ///
    /// The Thread UUID comes from `nodeId` (loaded from `thread-db/node-id` at startup),
    /// ensuring CIDs are unique across all nodes in the network without coordination.
    nonisolated func threadCID(localId: String) -> String {
        "\(nodeId.uuidString)-\(localId)"
    }
}
