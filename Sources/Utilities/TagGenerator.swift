//
//  TagGenerator.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 5/7/26.
//

import Foundation

/// Extracts high-frequency content words from document texts as topic tags.
///
/// Tokenizes on non-alphanumeric boundaries, filters stopwords and short tokens,
/// then ranks by frequency. Synchronous, no external dependencies, Linux-compatible.
enum TagGenerator {
    static let maxTags = 10

    static func generate(from texts: [String]) -> [String] {
        let combined = texts.joined(separator: " ")
        guard !combined.isEmpty else { return [] }
        var freq: [String: Int] = [:]
        combined.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopwords.contains($0) }
            .forEach { freq[$0, default: 0] += 1 }
        return freq
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxTags)
            .map { $0.key }
    }

    // MARK: - Private

    private static let stopwords: Set<String> = [
        "about", "above", "after", "again", "against", "also", "among", "another",
        "before", "being", "below", "between", "both", "been", "because",
        "cannot", "could", "dure", "each", "either", "even",
        "from", "further", "have", "having", "here", "however",
        "into", "itself", "just", "like", "many", "more", "most", "much",
        "need", "neither", "none", "only", "onto", "other", "otherwise", "over", "own",
        "same", "should", "since", "some", "such", "than", "that", "them",
        "then", "there", "therefore", "these", "they", "this", "those", "through",
        "thus", "time", "under", "until", "upon", "used", "very", "well",
        "were", "what", "when", "where", "which", "while", "will", "with",
        "within", "without", "would", "your", "yours",
    ]
}
