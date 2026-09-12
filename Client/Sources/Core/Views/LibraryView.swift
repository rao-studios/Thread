import SwiftUI

/// Groups and documents as the node reports them.
///
/// `/v1/library` already carries owner, access, `created_at` and group metadata;
/// the old client decoded only `{id, name}` and threw the rest away.
struct LibraryView: View {
    @EnvironmentObject private var appState: AppState

    @State private var groups: [WireGroup] = []
    @State private var loading = false
    @State private var error: String?
    @State private var includeAvailable = true
    @State private var selected: String?
    @State private var containing: [WireGroup] = []
    @State private var reExtracting: String?
    @State private var notice: String?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Color.sewnBorder)

            if let error { banner(error, tint: Color.sewnError) }
            if let notice { banner(notice, tint: Color.sewnGold) }

            if groups.isEmpty && !loading {
                emptyState
            } else {
                HSplitView {
                    list.frame(minWidth: 300, idealWidth: 380)
                    detail.frame(minWidth: 280)
                }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await reload()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Library")
                .font(.sewnSerif(15, weight: .medium))
                .foregroundStyle(Color.sewnInk)

            Text("\(groups.count) group\(groups.count == 1 ? "" : "s") · \(documentCount) document\(documentCount == 1 ? "" : "s")")
                .font(.sewnSans(10.5))
                .foregroundStyle(Color.sewnInk.opacity(0.35))

            Spacer()

            Toggle("Include public", isOn: $includeAvailable)
                .toggleStyle(.checkbox)
                .font(.sewnSans(11.5))
                .onChange(of: includeAvailable) { _, _ in Task { await reload() } }
                .help("Also list groups marked available to everyone.")

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
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var documentCount: Int {
        Set(groups.flatMap { ($0.documents ?? []).map(\.id) }).count
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.id) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        groupHeader(group)
                        ForEach(group.documents ?? [], id: \.id) { document in
                            documentRow(document)
                        }
                        if (group.documents ?? []).isEmpty {
                            Text("No documents")
                                .font(.sewnSans(11))
                                .foregroundStyle(Color.sewnInk.opacity(0.28))
                                .padding(.leading, 2)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func groupHeader(_ group: WireGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(group.label)
                    .font(.sewnSerif(13.5, weight: .medium))
                    .foregroundStyle(Color.sewnInk.opacity(0.85))
                tag(group.access ?? "unknown",
                    tint: group.access == "available" ? Color.sewnGold : Color.sewnInk.opacity(0.35))
                Spacer(minLength: 0)
                Text(group.ownerId)
                    .font(.sewnMono(9.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.30))
            }
            if let tags = group.metadata?.tags, !tags.isEmpty {
                Text(tags.joined(separator: " · "))
                    .font(.sewnSans(10))
                    .foregroundStyle(Color.sewnInk.opacity(0.30))
                    .lineLimit(1)
            }
            if let description = group.metadata?.description, !description.isEmpty {
                Text(description)
                    .font(.sewnSans(10.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.40))
            }
        }
    }

    private func documentRow(_ document: WireDocument) -> some View {
        let isSelected = selected == document.id
        return Button {
            selected = document.id
            Task { await loadContaining(document.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.sewnInk.opacity(0.30))
                Text(document.name ?? String(document.id.prefix(10)) + "…")
                    .font(.sewnSans(11.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let created = document.createdAt {
                    Text(created, format: .dateTime.month().day())
                        .font(.sewnSans(9.5))
                        .foregroundStyle(Color.sewnInk.opacity(0.28))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isSelected ? Color.sewnGold.opacity(0.10) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.sewnGold.opacity(0.22) : .clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selected, let document = document(for: id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(document.name ?? "Untitled")
                            .font(.sewnSerif(16, weight: .medium))
                            .foregroundStyle(Color.sewnInk)
                        Text(document.id)
                            .font(.sewnMono(9.5))
                            .foregroundStyle(Color.sewnInk.opacity(0.40))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text("Content-addressed: the id is a hash of the text's keyword profile, which is why near-identical documents dedupe.")
                            .font(.sewnSans(10))
                            .foregroundStyle(Color.sewnInk.opacity(0.28))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 16) {
                        if let owner = document.ownerId { figure("Owner", owner) }
                        if let created = document.createdAt {
                            figure("Indexed", created.formatted(date: .abbreviated, time: .shortened))
                        }
                    }

                    if !containing.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            sectionLabel("Groups containing it")
                            ForEach(containing, id: \.id) { group in
                                HStack(spacing: 6) {
                                    Text(group.label)
                                        .font(.sewnSans(11.5))
                                        .foregroundStyle(Color.sewnInk.opacity(0.70))
                                    tag(group.access ?? "unknown")
                                }
                            }
                        }
                    }

                    Divider().background(Color.sewnBorder)

                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Re-extract graph")
                        Text("Re-runs entity and relationship extraction under the current policy. Blocks until the extractor finishes.")
                            .font(.sewnSans(10.5))
                            .foregroundStyle(Color.sewnInk.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button(reExtracting == document.id ? "Re-extracting…" : "Re-extract") {
                                Task { await reExtract(document.id) }
                            }
                            .font(.sewnSans(11.5))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.sewnGold)
                            .disabled(reExtracting != nil)

                            if reExtracting == document.id {
                                ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
                            }
                        }
                    }

                    // Deletion and access changes are gRPC-only; the Store pane
                    // can show the text but nothing here can remove it.
                    Text("Deleting this document, or changing its access or group, isn't available over HTTP.")
                        .font(.sewnSans(10))
                        .foregroundStyle(Color.sewnInk.opacity(0.28))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 7) {
                Spacer()
                Image(systemName: "books.vertical")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.sewnInk.opacity(0.18))
                Text("Select a document")
                    .font(.sewnSerif(13, italic: true))
                    .foregroundStyle(Color.sewnInk.opacity(0.32))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        VStack(spacing: 11) {
            Spacer()
            ZStack {
                DatabaseOrbitRings(iconSize: 64)
                DatabaseSpinningIcon(size: 64, cornerRadius: 16)
            }
            Text("Nothing indexed yet")
                .font(.sewnSerif(14, italic: true))
                .foregroundStyle(Color.sewnInk.opacity(0.45))
            Text("Stage documents in the Index pane.")
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.28))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.sewnSans(11.5))
                .foregroundStyle(Color.sewnInk.opacity(0.75))
            Text(title.uppercased())
                .font(.sewnSans(8.5))
                .tracking(1.1)
                .foregroundStyle(Color.sewnInk.opacity(0.32))
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.sewnSans(9.5))
            .tracking(1.3)
            .foregroundStyle(Color.sewnInk.opacity(0.35))
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

    private func banner(_ message: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                error = nil
                notice = nil
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

    // MARK: - Data

    private func document(for id: String) -> WireDocument? {
        groups.flatMap { $0.documents ?? [] }.first { $0.id == id }
    }

    private func reload() async {
        loading = true
        error = nil
        do {
            groups = try await appState.api.library(includeAvailable: includeAvailable)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func loadContaining(_ id: String) async {
        containing = []
        do {
            containing = try await appState.api.groupsContaining(documentId: id)
        } catch {
            // Non-essential detail; the wire log carries the reason.
        }
    }

    private func reExtract(_ id: String) async {
        reExtracting = id
        error = nil
        notice = nil
        do {
            let result = try await appState.api.reExtract(documentId: id)
            notice = result.success
                ? "Re-extracted — \(result.entityCount ?? 0) entit\(result.entityCount == 1 ? "y" : "ies") now linked to this document."
                : "The node couldn't re-extract this document."
        } catch {
            self.error = error.localizedDescription
        }
        reExtracting = nil
    }
}
