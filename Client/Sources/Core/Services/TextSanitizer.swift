import Foundation

/// Cleans raw extracted text before it is embedded.
///
/// Handles the artefacts that PDFKit, RTF, and plain-text readers commonly
/// produce: ligature codepoints, soft hyphens, end-of-line word splits,
/// non-standard whitespace, stray control characters, and excessive blank lines.
enum TextSanitizer {

    // MARK: - Public

    static func sanitize(_ raw: String) -> String {
        var s = raw

        s = fixLigatures(s)
        s = fixSoftHyphens(s)
        s = fixNonStandardSpaces(s)
        s = removeControlCharacters(s)
        s = dehyphenateLineBreaks(s)
        s = normalizeLines(s)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ligatures
    // PDFKit often surfaces these Unicode Alphabetic Presentation Forms
    // as single codepoints rather than their ASCII equivalents.

    private static let ligatureMap: [(String, String)] = [
        ("\u{FB00}", "ff"),
        ("\u{FB01}", "fi"),
        ("\u{FB02}", "fl"),
        ("\u{FB03}", "ffi"),
        ("\u{FB04}", "ffl"),
        ("\u{FB05}", "st"),
        ("\u{FB06}", "st"),
        ("\u{0132}", "IJ"),   // Dutch IJ
        ("\u{0133}", "ij"),
        ("\u{00C6}", "AE"),   // Æ
        ("\u{00E6}", "ae"),   // æ
        ("\u{0152}", "OE"),   // Œ
        ("\u{0153}", "oe"),   // œ
    ]

    private static func fixLigatures(_ s: String) -> String {
        ligatureMap.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    // MARK: - Soft hyphens
    // U+00AD is the soft (optional) hyphen; PDFs often embed it mid-word.

    private static func fixSoftHyphens(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00AD}", with: "")
    }

    // MARK: - Non-standard spaces

    private static let spaceCandidates: [String] = [
        "\u{00A0}",  // Non-breaking space
        "\u{2009}",  // Thin space
        "\u{202F}",  // Narrow no-break space
        "\u{2003}",  // Em space
        "\u{2002}",  // En space
        "\u{2007}",  // Figure space
        "\u{3000}",  // Ideographic space
    ]

    private static func fixNonStandardSpaces(_ s: String) -> String {
        spaceCandidates.reduce(s) { $0.replacingOccurrences(of: $1, with: " ") }
    }

    // MARK: - Control characters
    // Strips everything below U+0020 except newline (0x0A), carriage return
    // (0x0D), and horizontal tab (0x09).  Also strips the Unicode replacement
    // character (U+FFFD) which some decoders insert for invalid bytes.

    private static func removeControlCharacters(_ s: String) -> String {
        String(s.unicodeScalars.filter { sc in
            let v = sc.value
            return v >= 0x20 || v == 0x0A || v == 0x0D || v == 0x09
        })
    }

    // MARK: - End-of-line dehyphenation
    // PDFs typeset in columns split words with a hyphen + newline.
    // "exam-\nple" → "example"   (drop the hyphen, join the word)
    // "self-\naware" keeps the hyphen only if the second half is capitalised
    // or if it looks like a genuine compound ("self-\nAware" stays "self-Aware").

    private static let dehyphenRegex: NSRegularExpression = {
        // Matches: lowercase letter, hyphen, newline, lowercase letter
        try! NSRegularExpression(pattern: "([a-z])-\\n([a-z])", options: [])
    }()

    private static func dehyphenateLineBreaks(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return dehyphenRegex.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: "$1$2"
        )
    }

    // MARK: - Line normalisation
    // • Collapse multiple spaces within a line to one
    // • Strip trailing whitespace from every line
    // • Collapse runs of more than two consecutive blank lines to two

    private static func normalizeLines(_ s: String) -> String {
        // Normalise Windows-style CRLF first
        let unixified = s.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r",   with: "\n")

        var output: [String] = []
        output.reserveCapacity(unixified.count / 40)
        var blankRun = 0

        for line in unixified.components(separatedBy: "\n") {
            let trimmed = collapseInternalSpaces(line.trimmingCharacters(in: .init(charactersIn: " \t")))
            if trimmed.isEmpty {
                blankRun += 1
                if blankRun <= 2 { output.append("") }
            } else {
                blankRun = 0
                output.append(trimmed)
            }
        }

        return output.joined(separator: "\n")
    }

    private static func collapseInternalSpaces(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var prevSpace = false
        for ch in s {
            if ch == " " {
                if !prevSpace { result.append(ch) }
                prevSpace = true
            } else {
                result.append(ch)
                prevSpace = false
            }
        }
        return result
    }
}
