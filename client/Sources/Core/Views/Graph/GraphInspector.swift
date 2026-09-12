import SwiftUI

/// Detail and mutation for whatever is selected on the canvas.
///
/// Mutations act on the selection rather than a free-typed id: entity ids are
/// long content hashes and there is no lookup-by-id route, so a typo would be
/// unrecoverable.
struct GraphInspector: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var simulation: GraphSimulation

    @Binding var selection: GraphSelection?
    /// Re-query after a mutation. Rename, merge and set-kind all re-key the
    /// entity server-side, so the canvas has to be rebuilt from the server's
    /// answer rather than patched locally.
    var onChanged: () async -> Void

    @State private var draftName = ""
    @State private var draftKind = ""
    @State private var mergeTarget = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var confirming: PendingAction?

    private enum PendingAction: Identifiable {
        case deleteEntity(id: String, name: String)
        case deleteRelationship(id: String, label: String)
        case merge(from: String, fromName: String, into: String, intoName: String)

        var id: String {
            switch self {
            case .deleteEntity(let id, _):       return "de-\(id)"
            case .deleteRelationship(let id, _): return "dr-\(id)"
            case .merge(let from, _, let into, _): return "m-\(from)-\(into)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch selection {
                case .entity(let id):
                    if let index = simulation.layout.ordinal[id] {
                        entityPanel(simulation.layout.nodes[index], id: id)
                    } else {
                        placeholder("That entity is no longer in the graph.")
                    }
                case .relationship(let id):
                    if let edge = simulation.layout.edges.first(where: { $0.id == id }) {
                        relationshipPanel(edge)
                    } else {
                        placeholder("That relationship is no longer in the graph.")
                    }
                case .none:
                    placeholder("Select a node or an edge.")
                }

                if let notice {
                    Text(notice)
                        .font(.sewnSans(11))
                        .foregroundStyle(Color.sewnInk.opacity(0.45))
                }
                if let error {
                    Text(error)
                        .font(.sewnSans(11))
                        .foregroundStyle(Color.sewnError)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.sewnBG)
        .onChange(of: selection) { _, _ in syncDrafts() }
        .onAppear { syncDrafts() }
        .alert(item: $confirming) { action in confirmation(action) }
    }

    // MARK: - Entity

    private func entityPanel(_ node: GraphLayout.Node, id: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            header(node.name, subtitle: node.kind, color: EntityPalette.color(for: node.kind))

            facts([
                ("Mentions", "\(node.mentionCount)"),
                ("Documents", "\(node.documentIds.count)"),
                ("Degree", "\(degree(of: id))"),
            ])

            labelled("Entity id") {
                Text(id)
                    .font(.sewnMono(9.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.45))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Divider().background(Color.sewnBorder)

            labelled("Rename") {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        TextField(node.name, text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .font(.sewnSans(12))
                            .onSubmit { Task { await rename(id: id) } }
                        Button("Apply") { Task { await rename(id: id) } }
                            .font(.sewnSans(11.5))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.sewnGold)
                            .disabled(busy || draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    // Renaming is a re-key on (kind, name). If that identity is
                    // already taken the server silently folds the two together.
                    Text("Renaming onto an existing name of the same kind merges the two entities.")
                        .font(.sewnSans(10))
                        .foregroundStyle(Color.sewnInk.opacity(0.30))
                }
            }

            labelled("Kind") {
                HStack(spacing: 6) {
                    TextField(node.kind, text: $draftKind)
                        .textFieldStyle(.roundedBorder)
                        .font(.sewnMono(11))
                        .onSubmit { Task { await setKind(id: id) } }
                    Button("Apply") { Task { await setKind(id: id) } }
                        .font(.sewnSans(11.5))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.sewnGold)
                        .disabled(busy || draftKind.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            labelled("Merge into") {
                HStack(spacing: 6) {
                    Picker("", selection: $mergeTarget) {
                        Text("Choose…").tag("")
                        ForEach(mergeCandidates(excluding: id), id: \.id) { candidate in
                            Text(candidate.name).tag(candidate.id)
                        }
                    }
                    .labelsHidden()
                    .font(.sewnSans(11.5))

                    Button("Merge") {
                        guard let target = simulation.layout.ordinal[mergeTarget] else { return }
                        confirming = .merge(
                            from: id, fromName: node.name,
                            into: mergeTarget, intoName: simulation.layout.nodes[target].name
                        )
                    }
                    .font(.sewnSans(11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.sewnGold)
                    .disabled(busy || mergeTarget.isEmpty)
                }
            }

            HStack(spacing: 10) {
                if let index = simulation.layout.ordinal[id] {
                    Button(simulation.layout.pinned[index] ? "Unpin" : "Pin") {
                        simulation.setPinned(index, !simulation.layout.pinned[index])
                    }
                    .font(.sewnSans(11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.sewnInk.opacity(0.55))
                }

                Spacer()

                Button("Delete") {
                    confirming = .deleteEntity(id: id, name: node.name)
                }
                .font(.sewnSans(11.5))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnError)
                .disabled(busy)
            }

            authorizationNote
        }
    }

    // MARK: - Relationship

    private func relationshipPanel(_ edge: GraphLayout.Edge) -> some View {
        let subject = simulation.layout.nodes[safe: edge.a]?.name ?? "?"
        let object = simulation.layout.nodes[safe: edge.b]?.name ?? "?"

        return VStack(alignment: .leading, spacing: 15) {
            header(edge.predicate, subtitle: "relationship", color: Color.sewnGold)

            labelled("Triple") {
                Text("\(subject) → \(edge.predicate) → \(object)")
                    .font(.sewnSans(12))
                    .foregroundStyle(Color.sewnInk.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            facts([
                ("Weight", "\(edge.weight)"),
                ("Documents", "\(edge.documentIds.count)"),
            ])

            labelled("Relationship id") {
                Text(edge.id)
                    .font(.sewnMono(9.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.45))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack {
                Spacer()
                Button("Delete") {
                    confirming = .deleteRelationship(
                        id: edge.id,
                        label: "\(subject) → \(edge.predicate) → \(object)"
                    )
                }
                .font(.sewnSans(11.5))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnError)
                .disabled(busy)
            }

            authorizationNote
        }
    }

    // MARK: - Pieces

    private var authorizationNote: some View {
        Text("Graph edits are unauthenticated and global — they affect every owner's view of this entity.")
            .font(.sewnSans(10))
            .foregroundStyle(Color.sewnInk.opacity(0.28))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color.opacity(0.8)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.sewnSerif(16, weight: .medium))
                    .foregroundStyle(Color.sewnInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.sewnMono(10))
                    .foregroundStyle(Color.sewnInk.opacity(0.38))
            }
            Spacer(minLength: 0)
            if busy { ProgressView().scaleEffect(0.45).frame(width: 14, height: 14) }
        }
    }

    private func facts(_ items: [(String, String)]) -> some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.1)
                        .font(.sewnMono(13))
                        .foregroundStyle(Color.sewnInk.opacity(0.80))
                    Text(item.0.uppercased())
                        .font(.sewnSans(8.5))
                        .tracking(1.1)
                        .foregroundStyle(Color.sewnInk.opacity(0.32))
                }
            }
        }
    }

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.sewnSans(9))
                .tracking(1.2)
                .foregroundStyle(Color.sewnInk.opacity(0.32))
            content()
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.sewnSerif(12.5, italic: true))
                .foregroundStyle(Color.sewnInk.opacity(0.32))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmation(_ action: PendingAction) -> Alert {
        switch action {
        case .deleteEntity(let id, let name):
            return Alert(
                title: Text("Delete “\(name)”?"),
                message: Text("This removes the entity and its relationships from the graph for every owner. It cannot be undone."),
                primaryButton: .destructive(Text("Delete")) { Task { await deleteEntity(id: id) } },
                secondaryButton: .cancel()
            )
        case .deleteRelationship(let id, let label):
            return Alert(
                title: Text("Delete this relationship?"),
                message: Text(label),
                primaryButton: .destructive(Text("Delete")) { Task { await deleteRelationship(id: id) } },
                secondaryButton: .cancel()
            )
        case .merge(let from, let fromName, let into, let intoName):
            return Alert(
                title: Text("Merge “\(fromName)” into “\(intoName)”?"),
                message: Text("“\(fromName)” stops existing. Its documents and relationships move to “\(intoName)”."),
                primaryButton: .destructive(Text("Merge")) { Task { await merge(from: from, into: into) } },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Helpers

    private func degree(of id: String) -> Int {
        guard let index = simulation.layout.ordinal[id] else { return 0 }
        return simulation.layout.edges.count { $0.a == index || $0.b == index }
    }

    private func mergeCandidates(excluding id: String) -> [GraphLayout.Node] {
        simulation.layout.nodes.filter { $0.id != id }.sorted { $0.name < $1.name }
    }

    private func syncDrafts() {
        error = nil
        notice = nil
        mergeTarget = ""
        if let id = selection?.entityId, let index = simulation.layout.ordinal[id] {
            draftName = simulation.layout.nodes[index].name
            draftKind = simulation.layout.nodes[index].kind
        } else {
            draftName = ""
            draftKind = ""
        }
    }

    // MARK: - Mutations

    private func rename(id: String) async {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        await mutate(describing: "Renamed to “\(name)”") {
            try await appState.api.renameEntity(id: id, name: name)
        }
    }

    private func setKind(id: String) async {
        let kind = draftKind.trimmingCharacters(in: .whitespaces)
        guard !kind.isEmpty else { return }
        await mutate(describing: "Kind set to “\(kind)”") {
            try await appState.api.setEntityKind(id: id, kind: kind)
        }
    }

    private func merge(from: String, into: String) async {
        await mutate(describing: "Merged") {
            try await appState.api.mergeEntities(from: from, into: into)
        }
    }

    private func deleteEntity(id: String) async {
        // The server reports success unconditionally here, so the honest claim
        // is that it's gone from this view — the re-query is what confirms it.
        await mutate(describing: "Removed from view", clearSelection: true) {
            try await appState.api.deleteEntity(id: id)
        }
    }

    private func deleteRelationship(id: String) async {
        await mutate(describing: "Removed from view", clearSelection: true) {
            try await appState.api.deleteRelationship(id: id)
        }
    }

    /// Run a mutation, adopt the surviving id, and rebuild from the server.
    private func mutate(describing message: String,
                        clearSelection: Bool = false,
                        _ operation: @escaping () async throws -> GraphMutationResponseDTO) async {
        busy = true
        error = nil
        notice = nil
        do {
            let result = try await operation()
            if result.success {
                notice = message
                // Rename/merge/set-kind re-key the entity: the id we hold is
                // dead, and `surviving_id` is the one that lives.
                selection = (clearSelection || result.survivingId == nil)
                    ? nil
                    : .entity(result.survivingId!)
            } else {
                error = "The node reported no change."
            }
            await onChanged()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
