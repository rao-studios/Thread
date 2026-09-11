import Foundation

enum HTMLExtractor {

    static func extract(_ html: String) -> String {
        var s = html

        // Remove entire block content we don't want in output
        s = stripBlocks(s, tag: "script")
        s = stripBlocks(s, tag: "style")
        s = stripBlocks(s, tag: "head")
        s = stripBlocks(s, tag: "noscript")
        s = stripBlocks(s, tag: "nav")
        s = stripBlocks(s, tag: "footer")

        // Block-level elements → newline so paragraphs stay separated
        let blockTags = ["p", "div", "section", "article", "main", "header",
                         "h1", "h2", "h3", "h4", "h5", "h6",
                         "li", "tr", "blockquote", "pre", "figure", "figcaption"]
        for tag in blockTags {
            s = replaceTag(s, tag: tag, replacement: "\n")
        }
        s = replaceTag(s, tag: "br", replacement: "\n")
        s = replaceTag(s, tag: "hr", replacement: "\n")

        // Strip all remaining tags
        s = stripAllTags(s)

        // Decode HTML entities
        s = decodeEntities(s)

        // Normalise whitespace: collapse runs of blanks to max two newlines
        s = collapseWhitespace(s)

        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return html // fallback: return raw if extraction produced nothing
        }
        return s
    }

    // MARK: - Private helpers

    private static func stripBlocks(_ s: String, tag: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return s }
        return re.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: " "
        )
    }

    private static func replaceTag(_ s: String, tag: String, replacement: String) -> String {
        // Matches both opening (<p ...>) and closing (</p>) forms
        guard let re = try? NSRegularExpression(
            pattern: "</?\\s*\(tag)(\\s[^>]*)?>",
            options: [.caseInsensitive]
        ) else { return s }
        return re.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: replacement
        )
    }

    private static func stripAllTags(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return s }
        return re.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: ""
        )
    }

    private static func decodeEntities(_ s: String) -> String {
        var r = s
        // Named entities
        let named: [(String, String)] = [
            ("&amp;",   "&"),
            ("&lt;",    "<"),
            ("&gt;",    ">"),
            ("&quot;",  "\""),
            ("&apos;",  "'"),
            ("&nbsp;",  " "),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&lsquo;", "\u{2018}"),
            ("&rsquo;", "\u{2019}"),
            ("&ldquo;", "\u{201C}"),
            ("&rdquo;", "\u{201D}"),
            ("&hellip;","…"),
            ("&copy;",  "©"),
            ("&reg;",   "®"),
            ("&trade;", "™"),
        ]
        for (entity, char) in named {
            r = r.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }
        // Decimal numeric entities &#123;
        if let re = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let matches = re.matches(in: r, range: NSRange(r.startIndex..., in: r))
            for m in matches.reversed() {
                guard let range = Range(m.range, in: r),
                      let numRange = Range(m.range(at: 1), in: r),
                      let codePoint = UInt32(r[numRange]),
                      let scalar = Unicode.Scalar(codePoint) else { continue }
                r.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        // Hex numeric entities &#x1F600;
        if let re = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: []) {
            let matches = re.matches(in: r, range: NSRange(r.startIndex..., in: r))
            for m in matches.reversed() {
                guard let range = Range(m.range, in: r),
                      let numRange = Range(m.range(at: 1), in: r),
                      let codePoint = UInt32(r[numRange], radix: 16),
                      let scalar = Unicode.Scalar(codePoint) else { continue }
                r.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        return r
    }

    private static func collapseWhitespace(_ s: String) -> String {
        // Collapse inline spaces (not newlines) to single space per run
        guard let spaceRe = try? NSRegularExpression(pattern: "[ \\t]+", options: []) else { return s }
        var r = spaceRe.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: " "
        )
        // Collapse 3+ consecutive newlines to two
        guard let nlRe = try? NSRegularExpression(pattern: "\\n{3,}", options: []) else { return r }
        r = nlRe.stringByReplacingMatches(
            in: r,
            range: NSRange(r.startIndex..., in: r),
            withTemplate: "\n\n"
        )
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
