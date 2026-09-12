import SwiftUI

/// The partition text and stats for one document.
///
/// Both come from disk because neither is reachable over HTTP: search returns
/// only the partitions that matched a query, and per-document retrieval counts
/// and sentiment are exposed by no route at all.
struct DocumentDetailView: View {
    let reader: StoreReader
    let root: URL
    let documentId: String?
    let stats: StoreDocumentStats?
    let access: String?
    let owners: [String]?

    @State private var partitions: [StorePartition] = []
    @State private var document: StoreDocument?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Group {
            if documentId == nil {
                placeholder
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if let error { errorBlock(error) }
                        if let stats { statsBlock(stats) }
                        partitionsBlock
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color.sewnBG)
        .task(id: documentId) { await load() }
    }

    private var placeholder: some View {
        VStack(spacing: 7) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.sewnInk.opacity(0.18))
            Text("Select a document")
                .font(.sewnSerif(13, italic: true))
                .foregroundStyle(Color.sewnInk.opacity(0.32))
            Text("Its stored text and stats are read from the data directory.")
                .font(.sewnSans(10.5))
                .foregroundStyle(Color.sewnInk.opacity(0.25))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 26)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(document?.name ?? "Untitled document")
                .font(.sewnSerif(16, weight: .medium))
                .foregroundStyle(Color.sewnInk)

            if let documentId {
                Text(documentId)
                    .font(.sewnMono(9.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.40))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack(spacing: 12) {
                if let access {
                    metaTag("access", access)
                }
                if let owners, !owners.isEmpty {
                    metaTag("owners", owners.joined(separator: ", "))
                }
                if let created = document?.createdAt {
                    metaTag("indexed", created.formatted(date: .abbreviated, time: .shortened))
                }
            }

            // Access and group membership are read-only here: changing them is
            // a gRPC-only operation with no HTTP equivalent.
            Text("Read-only — access and group changes aren't exposed over HTTP.")
                .font(.sewnSans(10))
                .foregroundStyle(Color.sewnInk.opacity(0.28))
        }
    }

    private func metaTag(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.70))
                .lineLimit(1)
            Text(label.uppercased())
                .font(.sewnSans(8.5))
                .tracking(1.1)
                .foregroundStyle(Color.sewnInk.opacity(0.30))
        }
    }

    private func statsBlock(_ stats: StoreDocumentStats) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            label("Stats")
            HStack(spacing: 18) {
                figure("Retrievals", "\(stats.retrievalCount ?? 0)")
                figure("Avg sentiment", String(format: "%.2f", stats.averageSentiment))
                figure("Earned", String(format: "%.2f", stats.totalEarned ?? 0))
                if let last = stats.lastRetrieved {
                    figure("Last", last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Text("Retrieval counts and sentiment are stored but exposed by no API route.")
                .font(.sewnSans(10))
                .foregroundStyle(Color.sewnInk.opacity(0.28))
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.sewnMono(13))
                .foregroundStyle(Color.sewnInk.opacity(0.80))
            Text(title.uppercased())
                .font(.sewnSans(8.5))
                .tracking(1.1)
                .foregroundStyle(Color.sewnInk.opacity(0.32))
        }
    }

    private var partitionsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Partitions (\(partitions.count))")

            if loading {
                ProgressView().scaleEffect(0.5)
            } else if partitions.isEmpty && error == nil {
                Text("No stored partition text for this document.")
                    .font(.sewnSans(11.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.32))
            }

            ForEach(Array(partitions.enumerated()), id: \.element.id) { index, partition in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("#\(index + 1)")
                            .font(.sewnMono(9.5))
                            .foregroundStyle(Color.sewnGold)
                        Text(partition.id.prefix(12) + "…")
                            .font(.sewnMono(9))
                            .foregroundStyle(Color.sewnInk.opacity(0.35))
                        Spacer()
                        if let type = partition.mediaType {
                            Text(type)
                                .font(.sewnMono(9))
                                .foregroundStyle(Color.sewnInk.opacity(0.30))
                        }
                    }
                    Text(partition.data)
                        .font(.sewnSans(11.5))
                        .foregroundStyle(Color.sewnInk.opacity(0.78))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sewnCard)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sewnBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func errorBlock(_ message: String) -> some View {
        Text(message)
            .font(.sewnSans(11))
            .foregroundStyle(Color.sewnError)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.sewnSans(9.5))
            .tracking(1.3)
            .foregroundStyle(Color.sewnInk.opacity(0.35))
    }

    private func load() async {
        guard let documentId else {
            partitions = []
            document = nil
            error = nil
            return
        }
        loading = true
        error = nil
        document = await reader.document(id: documentId, in: root)
        switch await reader.partitions(documentId: documentId, in: root) {
        case .success(let value):
            partitions = value
        case .failure(let failure):
            partitions = []
            error = failure.errorDescription
        }
        loading = false
    }
}
