import SwiftUI

struct GraphView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var simulation = GraphSimulation()

    @State private var seedEntity = ""
    @State private var seedQuery = ""
    @State private var hops = 1
    @State private var limit = 50
    @State private var kindFilter: String = ""
    @State private var loading = false
    @State private var error: String?
    @State private var selection: GraphSelection?
    @State private var stats: GraphResponseDTO.Stats?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Color.sewnBorder)

            if let error {
                banner(error)
            }

            HSplitView {
                canvas
                    .frame(minWidth: 380)

                GraphInspector(
                    simulation: simulation,
                    selection: $selection,
                    onChanged: { await refresh(preservingSeed: true) }
                )
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 400)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await refresh(preservingSeed: false)
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            if simulation.layout.isEmpty && !loading {
                emptyState
            } else {
                GraphCanvasView(
                    simulation: simulation,
                    selection: $selection,
                    onExpand: { entityId in
                        Task { await expand(entityId) }
                    }
                )
            }

            if loading {
                VStack(spacing: 10) {
                    DatabaseSpinningIcon(size: 34, cornerRadius: 9, opacity: 0.85)
                    Text("Querying…")
                        .font(.sewnSerif(12, italic: true))
                        .foregroundStyle(Color.sewnInk.opacity(0.35))
                }
            }
        }
        .overlay(alignment: .bottomLeading) { caption }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.sewnInk.opacity(0.18))
            Text("No entities")
                .font(.sewnSerif(14, italic: true))
                .foregroundStyle(Color.sewnInk.opacity(0.35))
            Text("Index a document, or widen the seed.")
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.25))
        }
    }

    /// Browse mode returns the top `limit` entities by mention count, not the
    /// whole graph — saying so keeps a truncated view from reading as a small
    /// graph.
    @ViewBuilder
    private var caption: some View {
        if let stats, !simulation.layout.isEmpty {
            let shown = simulation.layout.nodes.count
            let truncated = stats.entityCount > shown
            Text(truncated
                 ? "Showing \(shown) of \(stats.entityCount) entities · \(stats.relationshipCount) relationships"
                 : "\(shown) entities · \(simulation.layout.edges.count) relationships")
                .font(.sewnSans(10))
                .foregroundStyle(Color.sewnInk.opacity(0.35))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(14)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            field("Entity", text: $seedEntity, placeholder: "name", width: 130)
            field("Query", text: $seedQuery, placeholder: "free text", width: 150)
            field("Kind", text: $kindFilter, placeholder: "any", width: 90)

            HStack(spacing: 5) {
                Text("Hops")
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk.opacity(0.50))
                // The server clamps to 0...3; matching that here avoids a
                // control that silently does nothing.
                Stepper(value: $hops, in: 0...3) {
                    Text("\(hops)")
                        .font(.sewnMono(11.5))
                        .foregroundStyle(Color.sewnInk.opacity(0.80))
                }
                .frame(width: 74)
            }

            HStack(spacing: 5) {
                Text("Limit")
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk.opacity(0.50))
                Stepper(value: $limit, in: 5...300, step: 5) {
                    Text("\(limit)")
                        .font(.sewnMono(11.5))
                        .foregroundStyle(Color.sewnInk.opacity(0.80))
                }
                .frame(width: 84)
            }

            Button(loading ? "Querying…" : "Query") {
                Task { await refresh(preservingSeed: true) }
            }
            .font(.sewnSans(12))
            .buttonStyle(.borderedProminent)
            .tint(Color.sewnGold)
            .disabled(loading)

            if !seedEntity.isEmpty || !seedQuery.isEmpty || !kindFilter.isEmpty {
                Button("Browse") {
                    seedEntity = ""
                    seedQuery = ""
                    kindFilter = ""
                    Task { await refresh(preservingSeed: false) }
                }
                .font(.sewnSans(11.5))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnGold)
                .help("Clear the seed and show top entities by mention count")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func field(_ label: String,
                       text: Binding<String>,
                       placeholder: String,
                       width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.50))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.sewnMono(11))
                .frame(width: width)
                .onSubmit { Task { await refresh(preservingSeed: true) } }
        }
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.sewnError)
            Text(message)
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.65))
                .lineLimit(2)
            Spacer()
            Button { error = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.sewnInk.opacity(0.3))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.sewnError.opacity(0.05))
    }

    // MARK: - Loading

    private var kinds: [String]? {
        let trimmed = kindFilter.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : [trimmed]
    }

    private func refresh(preservingSeed: Bool) async {
        loading = true
        error = nil
        do {
            let response = try await appState.api.graph(
                entity: preservingSeed ? seedEntity : nil,
                query: preservingSeed ? seedQuery : nil,
                kinds: preservingSeed ? kinds : nil,
                hops: hops,
                limit: limit
            )
            stats = response.stats
            simulation.reset(with: response, size: simulation.layout.bounds)
            // The selected node may not exist any more after a re-query.
            if let id = selection?.entityId, simulation.layout.ordinal[id] == nil {
                selection = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Double-click traversal: query outward from one entity and merge the
    /// result into the existing picture rather than replacing it.
    private func expand(_ entityId: String) async {
        guard let index = simulation.layout.ordinal[entityId] else { return }
        let name = simulation.layout.nodes[index].name

        loading = true
        error = nil
        do {
            let response = try await appState.api.graph(
                entity: name,
                kinds: kinds,
                hops: max(hops, 1),
                limit: limit
            )
            if let count = response.stats { stats = count }
            simulation.merge(response, expandedFrom: entityId)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
