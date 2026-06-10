//
//  Database+Utilities.swift
//  database-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation
import Crypto

// MARK: - Hashes

/// Two/three-digit decimal representation of each byte value, exactly matching
/// the historical `String(format: "%02d", byte)` output (bytes ≥ 100 produce
/// three digits). Hash strings are persisted document/partition IDs, so this
/// encoding must remain byte-identical forever.
private let byteDecimalStrings: [String] = (0...255).map { String(format: "%02d", $0) }

@inline(__always)
private func decimalString<Bytes: Sequence>(of bytes: Bytes) -> String where Bytes.Element == UInt8 {
    var out = String()
    out.reserveCapacity(96)  // 32 SHA-256 bytes × up to 3 digits
    for byte in bytes { out += byteDecimalStrings[Int(byte)] }
    return out
}

extension Database {
    nonisolated func computeHash(from texts: [String]) -> String {
        let text = texts.joined(separator: " ")
        
        // Step 1: Tokenize and preprocess
        func preprocess(_ text: String) -> [String] {
            let lowercase = text.lowercased()
            let words = lowercase.components(separatedBy: .whitespacesAndNewlines)
            let stopWords = Set(["the", "and", "a", "an", "in", "on", "at", "for", "of", "to", "is", "it", "that", "this"])
            let punctuation = CharacterSet.punctuationCharacters
            var tokens = [String]()
            for word in words {
                let trimmed = word.trimmingCharacters(in: punctuation)
                if !trimmed.isEmpty && !stopWords.contains(trimmed) {
                    tokens.append(trimmed)
                }
            }
            return tokens
        }
        
        let tokens = preprocess(text)
        
        // Step 2: Compute word frequencies
        var wordFreq = [String: Int]()
        for token in tokens {
            wordFreq[token] = (wordFreq[token] ?? 0) + 1
        }
        
        // Step 3: Select top N words by frequency with deterministic tie-breaking
        let topN = 10
        let sortedWords = wordFreq.sorted { (lhs, rhs) in
            // Primary sort: frequency descending
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            // Tie-breaker: lexicographic order ascending
            return lhs.key < rhs.key
        }
        let topWords = sortedWords.prefix(topN).map { $0.key }
        
        // Step 4: Sort alphabetically (already deterministic)
        let sortedTopWords = topWords.sorted()
        let hashInput = sortedTopWords.joined(separator: " ")
        
        return Database.computeNumericHash(from: hashInput)
    }
    
    // Function to compute a numeric hash from a string
    static func computeNumericHash(from text: String) -> String {
        // Convert the string to a byte array using UTF-8 encoding
        let data = text.data(using: .utf8)!

        // Compute the SHA-256 hash of the byte array
        let hash = SHA256.hash(data: data)

        // Convert the hash to a numeric string
        return decimalString(of: hash)
    }

    // Function to compute a numeric hash from embeddings.
    // documentId is included in the hash so that the same embedding in two different
    // documents produces distinct partition IDs — preventing cross-document HNSW node
    // stealing that causes pq > hnsw divergence and missed results in group-scoped search.
    nonisolated func computeNumericHash(from embeddings: [Float], documentId: String? = nil) -> String {
        // One contiguous copy of the float buffer (native byte order — identical
        // to the historical per-float withUnsafeBytes appends).
        var data = embeddings.withUnsafeBufferPointer { Data(buffer: $0) }
        if let docId = documentId, let docIdBytes = docId.data(using: .utf8) {
            data.append(docIdBytes)
        }
        let hash = SHA256.hash(data: data)
        return decimalString(of: hash)
    }
}

