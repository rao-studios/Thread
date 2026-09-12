import SwiftUI
import UniformTypeIdentifiers

/// One document staged for indexing.
///
/// The batch route takes per-document `names`, `tags`, `entities` and
/// `relationships` as arrays aligned 1:1 with `inputs`, so each row here
/// becomes one index in every one of those arrays.
struct StagedDocument: Identifiable {
    let id = UUID()
    var url: URL?
    var name: String
    var text: String
    /// Comma-separated. Mapped to `concept` entities server-side.
    var tags: String = ""
    /// Comma-separated `name:kind` pairs; kind defaults to `concept`.
    var entities: String = ""
    /// One `subject | predicate | object` triple per line.
    var relationships: String = ""
    var mediaType: String = "text"
    var status: Status = .staged
    var expanded = false

    enum Status: Equatable {
        case reading
        case staged
        case sending
        /// Embedded and enqueued — indexing and enrichment run detached.
        case accepted
        case error(String)

        var label: String {
            switch self {
            case .reading:        return "Reading…"
            case .staged:         return "Staged"
            case .sending:        return "Sending…"
            case .accepted:       return "Accepted"
            case .error(let msg): return msg
            }
        }
    }

    var parsedTags: [String] {
        tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var parsedEntities: [WireEntityInput] {
        entities.split(separator: ",").compactMap { chunk in
            let parts = chunk.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let name = parts.first, !name.isEmpty else { return nil }
            let kind = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            return WireEntityInput(name: name, kind: kind)
        }
    }

    var parsedRelationships: [WireRelationInput] {
        relationships.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, !parts.contains(where: \.isEmpty) else { return nil }
            return WireRelationInput(subject: parts[0], predicate: parts[1], object: parts[2])
        }
    }
}

struct IndexView: View {
    @EnvironmentObject private var appState: AppState

    @State private var staged: [StagedDocument] = []
    @State private var sanitize = true
    @State private var sending = false
    @State private var error: String?
    @State private var receipt: String?
    @State private var isDropTargeted = false
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Color.sewnBorder)

            if let error { banner(error, tint: Color.sewnError) }
            if let receipt { banner(receipt, tint: Color.sewnGold) }

            if staged.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .overlay { if isDropTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .rtf, .rtfd, .plainText, .utf8PlainText,
                                  .html, .json, .commaSeparatedText, .sourceCode, .data, .item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { stage(urls) }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Index")
                .font(.sewnSerif(15, weight: .medium))
                .foregroundStyle(Color.sewnInk)

            Text("\(staged.count) staged")
                .font(.sewnSans(10.5))
                .foregroundStyle(Color.sewnInk.opacity(0.35))

            Spacer()

            Toggle("Sanitize", isOn: $sanitize)
                .toggleStyle(.checkbox)
                .font(.sewnSans(11.5))
                .help("Server-side chunking via TextChunker before embedding.")

            Button("Add files…") { showFilePicker = true }
                .font(.sewnSans(11.5))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnGold)

            if !staged.isEmpty {
                Button("Clear") {
                    staged.removeAll()
                    receipt = nil
                    error = nil
                }
                .font(.sewnSans(11.5))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnInk.opacity(0.45))
                .disabled(sending)
            }

            Button(sending ? "Indexing…" : "Index \(indexable.count > 1 ? "\(indexable.count) docs" : "")") {
                Task { await submit() }
            }
            .font(.sewnSans(12))
            .buttonStyle(.borderedProminent)
            .tint(Color.sewnGold)
            .disabled(sending || indexable.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var indexable: [StagedDocument] {
        staged.filter { !$0.text.isEmpty && $0.status != .sending }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach($staged) { $document in
                    row($document)
                }
            }
            .padding(18)
        }
    }

    private func row(_ document: Binding<StagedDocument>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Button {
                    document.wrappedValue.expanded.toggle()
                } label: {
                    Image(systemName: document.wrappedValue.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.sewnInk.opacity(0.35))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                TextField("name", text: document.name)
                    .textFieldStyle(.plain)
                    .font(.sewnSans(12.5, weight: .medium))
                    .foregroundStyle(Color.sewnInk.opacity(0.85))

                Spacer(minLength: 0)

                Text("\(document.wrappedValue.text.count) chars")
                    .font(.sewnMono(9.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.30))

                statusTag(document.wrappedValue.status)

                Button {
                    staged.removeAll { $0.id == document.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.sewnInk.opacity(0.30))
                }
                .buttonStyle(.plain)
                .disabled(sending)
            }

            if document.wrappedValue.expanded {
                VStack(alignment: .leading, spacing: 8) {
                    field("Tags", hint: "comma separated · become concept entities",
                          text: document.tags, mono: false)
                    field("Entities", hint: "name:kind, name:kind · kind defaults to concept",
                          text: document.entities, mono: true)
                    multiline("Relationships", hint: "one per line · subject | predicate | object",
                              text: document.relationships)

                    HStack(spacing: 7) {
                        Text("MEDIA TYPE")
                            .font(.sewnSans(9))
                            .tracking(1.2)
                            .foregroundStyle(Color.sewnInk.opacity(0.32))
                        Picker("", selection: document.mediaType) {
                            Text("text").tag("text")
                            Text("image").tag("image")
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        .font(.sewnSans(11))
                    }

                    DisclosureGroup("Extracted text") {
                        Text(document.wrappedValue.text)
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnInk.opacity(0.65))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 5)
                    }
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk.opacity(0.45))
                }
                .padding(.leading, 21)
            }
        }
        .padding(12)
        .background(Color.sewnCard)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.sewnBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func field(_ label: String, hint: String, text: Binding<String>, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.sewnSans(9))
                .tracking(1.2)
                .foregroundStyle(Color.sewnInk.opacity(0.32))
            TextField(hint, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .sewnMono(11) : .sewnSans(11.5))
        }
    }

    private func multiline(_ label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.sewnSans(9))
                .tracking(1.2)
                .foregroundStyle(Color.sewnInk.opacity(0.32))
            TextEditor(text: text)
                .font(.sewnMono(11))
                .frame(height: 54)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sewnBorder, lineWidth: 1))
            Text(hint)
                .font(.sewnSans(10))
                .foregroundStyle(Color.sewnInk.opacity(0.28))
        }
    }

    private func statusTag(_ status: StagedDocument.Status) -> some View {
        let tint: Color = {
            switch status {
            case .error:    return Color.sewnError
            case .accepted: return Color.sewnGold
            default:        return Color.sewnInk.opacity(0.40)
            }
        }()
        return Text(status.label)
            .font(.sewnSans(9.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
    }

    // MARK: - Empty / drop

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                DatabaseOrbitRings(iconSize: 64)
                DatabaseSpinningIcon(size: 64, cornerRadius: 16)
            }
            VStack(spacing: 5) {
                Text("Drop files to stage them")
                    .font(.sewnSerif(14, italic: true))
                    .foregroundStyle(Color.sewnInk.opacity(0.45))
                Text("Everything staged is indexed in a single batch call.")
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk.opacity(0.28))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.sewnGold.opacity(0.6),
                          style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
            .background(Color.sewnGold.opacity(0.05))
            .padding(10)
            .allowsHitTesting(false)
    }

    private func banner(_ message: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                error = nil
                receipt = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.sewnInk.opacity(0.30))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(tint.opacity(0.06))
    }

    // MARK: - Staging

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in stage([url]) }
            }
        }
    }

    private func stage(_ urls: [URL]) {
        for url in urls {
            var document = StagedDocument(url: url, name: url.lastPathComponent, text: "")
            document.status = .reading
            staged.append(document)
            let id = document.id
            Task { await read(id: id, url: url) }
        }
    }

    private func read(id: UUID, url: URL) async {
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                TextSanitizer.sanitize(try FileReader.extractText(from: url))
            }.value
            guard let index = staged.firstIndex(where: { $0.id == id }) else { return }
            if text.isEmpty {
                staged[index].status = .error("Empty file")
            } else {
                staged[index].text = text
                staged[index].status = .staged
            }
        } catch {
            if let index = staged.firstIndex(where: { $0.id == id }) {
                staged[index].status = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Submit

    private func submit() async {
        let batch = indexable
        guard !batch.isEmpty else { return }

        sending = true
        error = nil
        receipt = nil
        for index in staged.indices where batch.contains(where: { $0.id == staged[index].id }) {
            staged[index].status = .sending
        }

        do {
            let response = try await appState.api.index(
                batch.map {
                    .init(text: $0.text,
                          name: $0.name.isEmpty ? nil : $0.name,
                          tags: $0.parsedTags,
                          entities: $0.parsedEntities,
                          relationships: $0.parsedRelationships,
                          mediaType: $0.mediaType == "text" ? nil : $0.mediaType)
                },
                sanitize: sanitize
            )

            for index in staged.indices where batch.contains(where: { $0.id == staged[index].id }) {
                staged[index].status = .accepted
            }

            // `success` counts prepared + skipped + link-only, so it is true even
            // when a document was deduped away. Say what was actually promised.
            let tokens = response.usage?.total_tokens ?? 0
            receipt = response.success
                ? "Accepted \(batch.count) document\(batch.count == 1 ? "" : "s") · \(tokens) tokens. Indexing and graph enrichment continue in the background — documents aren't searchable until that finishes, and identical text is deduplicated rather than re-indexed."
                : "The node reported a partial batch — some inputs were dropped. Check the wire log."

        } catch {
            self.error = error.localizedDescription
            for index in staged.indices where batch.contains(where: { $0.id == staged[index].id }) {
                staged[index].status = .error("Failed")
            }
        }
        sending = false
    }
}
