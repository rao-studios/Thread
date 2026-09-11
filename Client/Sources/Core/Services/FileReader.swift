import Foundation
import PDFKit

/// Extracts the textual content of a file at a given URL.
///
/// Extraction is format-aware and always returns a raw string.
/// Call `TextSanitizer.sanitize(_:)` on the result before embedding.
enum FileReader {

    // MARK: - Public

    static func extractText(from url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return try extractPDF(url)

        case "rtf":
            return try extractRichText(url, type: .rtf)

        case "rtfd":
            return try extractRTFD(url)

        case "txt", "text":
            return try extractPlainText(url)

        case "md", "markdown":
            return try extractPlainText(url)

        case "html", "htm":
            return try extractHTML(url)

        // Source / data formats treated as plain text
        case "swift", "py", "js", "ts", "jsx", "tsx",
             "json", "csv", "xml",
             "css", "scss", "rs", "go", "java", "kt",
             "rb", "sh", "c", "cpp", "h", "m", "yaml", "toml":
            return try extractPlainText(url)

        default:
            // Best-effort: try UTF-8, then Latin-1
            if let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty { return s }
            if let s = try? String(contentsOf: url, encoding: .isoLatin1), !s.isEmpty { return s }
            throw FileReaderError.unsupportedFormat(ext.isEmpty ? "unknown" : ext)
        }
    }

    // MARK: - PDF

    private static func extractPDF(_ url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw FileReaderError.cannotRead
        }
        guard doc.pageCount > 0 else {
            throw FileReaderError.emptyContent
        }

        var pages: [String] = []
        pages.reserveCapacity(doc.pageCount)

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }

            // PDFPage.string includes all text on the page, including headers/
            // footers and watermarks. We keep it verbatim here; TextSanitizer
            // will normalise whitespace and fix ligatures.
            guard let raw = page.string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            pages.append(raw)
        }

        if pages.isEmpty { throw FileReaderError.emptyContent }

        // Page separator gives the chunker/model paragraph-level context.
        return pages.joined(separator: "\n\n")
    }

    // MARK: - Rich text (RTF)

    private static func extractRichText(_ url: URL, type: NSAttributedString.DocumentType) throws -> String {
        let data = try Data(contentsOf: url)
        let attr = try NSAttributedString(
            data: data,
            options: [.documentType: type],
            documentAttributes: nil
        )
        let s = attr.string
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FileReaderError.emptyContent
        }
        return s
    }

    // MARK: - RTFD (RTF with attachments — directory package)

    private static func extractRTFD(_ url: URL) throws -> String {
        // RTFD is a directory; NSAttributedString(url:) handles it natively.
        var attrs: NSDictionary? = nil
        guard let attr = try? NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: &attrs
        ) else {
            // Fallback: look for the TXT.rtf file inside the package
            let inner = url.appendingPathComponent("TXT.rtf")
            if FileManager.default.fileExists(atPath: inner.path) {
                return try extractRichText(inner, type: .rtf)
            }
            throw FileReaderError.cannotRead
        }
        let s = attr.string
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FileReaderError.emptyContent
        }
        return s
    }

    // MARK: - HTML

    private static func extractHTML(_ url: URL) throws -> String {
        let raw = try extractPlainText(url)
        return HTMLExtractor.extract(raw)
    }

    // MARK: - Plain text

    private static func extractPlainText(_ url: URL) throws -> String {
        // Attempt common encodings in order of likelihood
        let encodings: [String.Encoding] = [.utf8, .utf16, .isoLatin1, .windowsCP1252]
        for enc in encodings {
            if let s = try? String(contentsOf: url, encoding: enc), !s.isEmpty {
                return s
            }
        }
        throw FileReaderError.cannotRead
    }

    // MARK: - Errors

    enum FileReaderError: LocalizedError {
        case unsupportedFormat(String)
        case cannotRead
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext): return ".\(ext) files are not supported"
            case .cannotRead:                 return "Could not read file"
            case .emptyContent:               return "File appears to be empty"
            }
        }
    }
}
