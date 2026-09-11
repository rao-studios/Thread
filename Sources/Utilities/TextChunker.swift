//
//  TextChunker.swift
//  database-server
//

import Foundation

enum TextChunker {
    static let defaultMaxChars = 1500

    /// Chunks each element independently and flattens — elements within budget pass
    /// through as-is; oversized elements are split into multiple chunks.
    static func chunk(_ texts: [String], maxChars: Int = defaultMaxChars) -> [String] {
        texts.flatMap { chunk($0, maxChars: maxChars) }
    }

    /// Splits `text` into chunks of at most `maxChars` characters, respecting
    /// paragraph → sentence → hard-split boundaries in that order.
    static func chunk(_ text: String, maxChars: Int = defaultMaxChars) -> [String] {
        // 1. Paragraph-level candidates
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var buffer = ""

        for para in paragraphs {
            let segments = para.count <= maxChars
                ? [para]
                : splitBySentence(para, maxChars: maxChars)

            for seg in segments {
                if buffer.isEmpty {
                    buffer = seg
                } else if buffer.count + 2 + seg.count <= maxChars {
                    buffer += "\n\n" + seg
                } else {
                    chunks.append(buffer)
                    buffer = seg
                }
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
    }

    // MARK: - Private

    private static func splitBySentence(_ text: String, maxChars: Int) -> [String] {
        // Split on ". " or ".\n" as sentence boundaries.
        var sentences: [String] = []
        var current = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            current.append(ch)
            if ch == "." {
                let next = text.index(after: i)
                if next == text.endIndex || text[next] == " " || text[next] == "\n" {
                    sentences.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            i = text.index(after: i)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }

        var result: [String] = []
        var buf = ""
        for sent in sentences {
            let pieces = sent.count <= maxChars ? [sent] : hardSplit(sent, maxChars: maxChars)
            for piece in pieces {
                if buf.isEmpty {
                    buf = piece
                } else if buf.count + 1 + piece.count <= maxChars {
                    buf += " " + piece
                } else {
                    result.append(buf)
                    buf = piece
                }
            }
        }
        if !buf.isEmpty { result.append(buf) }
        return result
    }

    private static func hardSplit(_ text: String, maxChars: Int) -> [String] {
        stride(from: 0, to: text.count, by: maxChars).map { start in
            let s = text.index(text.startIndex, offsetBy: start)
            let e = text.index(s, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
            return String(text[s..<e])
        }
    }
}
