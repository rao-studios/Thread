import SwiftUI

/// The modes the client can be in. Search, Index, Graph and Library speak HTTP
/// to a running node; Store reads the data directory off disk and works with
/// the server stopped.
enum AppMode: String, CaseIterable, Identifiable {
    case search, index, graph, library, store, inspector

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search:    return "Search"
        case .index:     return "Index"
        case .graph:     return "Graph"
        case .library:   return "Library"
        case .store:     return "Store"
        case .inspector: return "Inspector"
        }
    }

    var icon: String {
        switch self {
        case .search:    return "magnifyingglass"
        case .index:     return "square.and.arrow.down"
        case .graph:     return "point.3.connected.trianglepath.dotted"
        case .library:   return "books.vertical"
        case .store:     return "internaldrive"
        case .inspector: return "waveform"
        }
    }

    var blurb: String {
        switch self {
        case .search:    return "Query the index"
        case .index:     return "Add documents"
        case .graph:     return "Traverse and edit"
        case .library:   return "Groups and documents"
        case .store:     return "Read the data directory"
        case .inspector: return "Wire log and policy"
        }
    }

    /// Whether this mode needs a reachable node.
    var requiresServer: Bool { self != .store }
}

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var mode: AppMode
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().background(Color.sewnBorder)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(AppMode.allCases) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }

            Spacer(minLength: 0)

            Divider().background(Color.sewnBorder)

            footer
        }
        .background(Color.sewnBG)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            DatabaseSpinningIcon(size: 26, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text("Thread")
                    .font(.sewnSerif(16, weight: .medium))
                    .foregroundStyle(Color.sewnInk)
                Text(appState.ownerId)
                    .font(.sewnMono(10))
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    // MARK: - Rows

    private func row(_ item: AppMode) -> some View {
        let selected = mode == item
        return Button {
            mode = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12))
                    .frame(width: 17)
                    .foregroundStyle(selected ? Color.sewnGold : Color.sewnInk.opacity(0.45))

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.sewnSans(12.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(Color.sewnInk.opacity(selected ? 0.90 : 0.70))
                    Text(item.blurb)
                        .font(.sewnSans(10))
                        .foregroundStyle(Color.sewnInk.opacity(0.30))
                }

                Spacer(minLength: 0)

                // Modes that need the node are dimmed when it's unreachable —
                // Store keeps working, which is the point of the disk lane.
                if item.requiresServer && appState.serverReachable == false {
                    Image(systemName: "bolt.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.sewnError.opacity(0.55))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.sewnGold.opacity(0.10) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.sewnGold.opacity(0.22) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            ServerStatusDot(reachable: appState.serverReachable)

            Button {
                Task { await appState.checkHealth() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help("Re-check the node")

            Spacer(minLength: 0)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
