import SwiftUI
import AppKit

/// The data directory, read straight off disk.
///
/// Everything here is read-only and lags the running node by up to its ~1s
/// flush debounce — hence the "as of" stamp. It is also the only place in the
/// client that can show document text, per-document stats, the registry, or
/// the graph's true size.
struct StoreView: View {
    @EnvironmentObject private var appState: AppState

    @State private var reader = StoreReader()
    @State private var snapshot: StoreReader.DirectorySnapshot?
    @State private var selectedNode: String?
    @State private var selectedDocument: String?
    @State private var loading = false
    @State private var loaded = false

    private var node: StoreReader.NodeSnapshot? {
        guard let snapshot else { return nil }
        return snapshot.nodes.first { $0.nodeId == selectedNode } ?? snapshot.nodes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Color.sewnBorder)

            if let snapshot, let error = snapshot.error, snapshot.nodes.isEmpty {
                message(error, isError: true)
            } else if let node {
                content(node)
            } else if loading {
                message("Reading…", isError: false)
            } else {
                message("Choose a data directory.", isError: false)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await reload()
        }
        .onChange(of: appState.dataDirectory) { _, _ in Task { await reload() } }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 12))
                .foregroundStyle(Color.sewnInk.opacity(0.40))

            Text(StoreReader.resolve(appState.dataDirectory).path)
                .font(.sewnMono(11))
                .foregroundStyle(Color.sewnInk.opacity(0.70))
                .lineLimit(1)
                .truncationMode(.head)
                .help(StoreReader.resolve(appState.dataDirectory).path)

            Button("Browse…") { chooseDirectory() }
                .font(.sewnSans(11.5))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnGold)

            if let snapshot, snapshot.nodes.count > 1 {
                Divider().frame(height: 14).background(Color.sewnBorder)
                Picker("", selection: Binding(
                    get: { selectedNode ?? snapshot.nodes.first?.nodeId ?? "" },
                    set: { selectedNode = $0; selectedDocument = nil }
                )) {
                    ForEach(snapshot.nodes, id: \.nodeId) { item in
                        Text(label(for: item)).tag(item.nodeId)
                    }
                }
                .labelsHidden()
                .frame(width: 230)
                .font(.sewnMono(11))
            }

            Spacer(minLength: 0)

            if let modified = node?.modified {
                Text("as of \(modified, style: .time)")
                    .font(.sewnSans(10.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
                    .help("On-disk state lags the running node by up to a second.")
            }

            Button {
                Task { await reload() }
            } label: {
                if loading {
                    ProgressView().scaleEffect(0.4).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sewnInk.opacity(0.40))
                }
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .help("Re-read from disk")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func label(for node: StoreReader.NodeSnapshot) -> String {
        let short = String(node.nodeId.prefix(8))
        return node.isCurrent ? "\(short)… (current)" : "\(short)…"
    }

    // MARK: - Content

    private func content(_ node: StoreReader.NodeSnapshot) -> some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !node.errors.isEmpty {
                        decodeWarning(node.errors)
                    }
                    counters(node)
                    documentList(node)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 320, idealWidth: 420)

            DocumentDetailView(
                reader: reader,
                root: StoreReader.resolve(appState.dataDirectory),
                documentId: selectedDocument,
                stats: selectedDocument.flatMap { node.registry?.documentStats[$0] },
                access: selectedDocument.map { node.registry?.access(forDocument: $0) ?? "unknown" },
                owners: selectedDocument.map { node.registry?.owners(forDocument: $0) ?? [] }
            )
            .frame(minWidth: 300)
        }
    }

    /// Model drift shows here rather than as a silently empty node.
    private func decodeWarning(_ errors: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.sewnError)
                Text("Some state couldn't be read")
                    .font(.sewnSans(11.5, weight: .medium))
                    .foregroundStyle(Color.sewnInk.opacity(0.70))
            }
            ForEach(errors, id: \.self) { error in
                Text(error)
                    .font(.sewnMono(10.5))
                    .foregroundStyle(Color.sewnError.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The client mirrors server-internal types; a rename on the server shows up here.")
                .font(.sewnSans(10))
                .foregroundStyle(Color.sewnInk.opacity(0.30))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sewnError.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sewnError.opacity(0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func counters(_ node: StoreReader.NodeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Node \(String(node.nodeId.prefix(8)))…\(node.isCurrent ? " · current" : "")")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 8)], spacing: 8) {
                counter("Documents", node.documentCount)
                counter("Groups", node.groupCount)
                counter("Owners", node.ownerCount)
                counter("Available", node.availableCount)
                counter("Entities", node.entityCount)
                counter("Relationships", node.relationshipCount)
                counter("Predicates", node.predicateCount)
                counter("Indexed", node.table?.keys.count ?? 0)
            }
        }
    }

    private func counter(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.sewnMono(17))
                .foregroundStyle(Color.sewnInk.opacity(0.85))
            Text(title.uppercased())
                .font(.sewnSans(8.5))
                .tracking(1.1)
                .foregroundStyle(Color.sewnInk.opacity(0.32))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.sewnCard)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sewnBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func documentList(_ node: StoreReader.NodeSnapshot) -> some View {
        let ids = node.registry?.documentIds ?? node.table?.keys.sorted() ?? []
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Documents (\(ids.count))")

            if ids.isEmpty {
                Text("No documents in this node.")
                    .font(.sewnSans(11.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.32))
            } else {
                VStack(spacing: 1) {
                    ForEach(ids, id: \.self) { id in
                        documentRow(id, node: node)
                    }
                }
            }
        }
    }

    private func documentRow(_ id: String, node: StoreReader.NodeSnapshot) -> some View {
        let selected = selectedDocument == id
        let partitions = node.table?.indices[id]?.slots?.count
        let entities = node.table?.indices[id]?.entityIds?.count
        let access = node.registry?.access(forDocument: id) ?? "unknown"

        return Button {
            selectedDocument = id
        } label: {
            HStack(spacing: 8) {
                Text(id.prefix(10) + "…")
                    .font(.sewnMono(10.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.70))

                Spacer(minLength: 0)

                if let partitions {
                    tag("\(partitions)p")
                }
                if let entities, entities > 0 {
                    tag("\(entities)e")
                }
                tag(access, tint: access == "available" ? Color.sewnGold : Color.sewnInk.opacity(0.35))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Color.sewnGold.opacity(0.10) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.sewnGold.opacity(0.22) : .clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String, tint: Color = Color.sewnInk.opacity(0.35)) -> some View {
        Text(text)
            .font(.sewnMono(9))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.sewnFill)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.sewnSans(9.5))
            .tracking(1.3)
            .foregroundStyle(Color.sewnInk.opacity(0.35))
    }

    private func message(_ text: String, isError: Bool) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: isError ? "exclamationmark.triangle" : "internaldrive")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(isError ? Color.sewnError.opacity(0.6) : Color.sewnInk.opacity(0.18))
            Text(text)
                .font(.sewnSans(12))
                .foregroundStyle(isError ? Color.sewnError : Color.sewnInk.opacity(0.35))
                .multilineTextAlignment(.center)
            Text("The store lane reads the node's files directly — it works with the server stopped.")
                .font(.sewnSans(10.5))
                .foregroundStyle(Color.sewnInk.opacity(0.25))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }

    // MARK: - Actions

    private func reload() async {
        loading = true
        let url = StoreReader.resolve(appState.dataDirectory)
        let result = await reader.load(directory: url)
        snapshot = result
        if selectedNode == nil || !result.nodes.contains(where: { $0.nodeId == selectedNode }) {
            selectedNode = result.nodes.first(where: \.isCurrent)?.nodeId ?? result.nodes.first?.nodeId
        }
        loading = false
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = StoreReader.resolve(appState.dataDirectory)
        panel.prompt = "Choose"
        panel.message = "Pick a Thread data directory (the one holding node-id)."
        if panel.runModal() == .OK, let url = panel.url {
            appState.dataDirectory = url.path
        }
    }
}
