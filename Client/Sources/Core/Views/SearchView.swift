import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""

    private enum Phase { case idle, searching, results }

    private var phase: Phase {
        if appState.isSearching { return .searching }
        if !appState.searchResults.isEmpty || appState.searchError != nil { return .results }
        return .idle
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.sewnBG.ignoresSafeArea()

                // Ambient warm glow — fades when results show
                ambientGlow(geo: geo)

                VStack(spacing: 0) {
                    // Compact header — visible in results/searching
                    if phase != .idle {
                        compactHeader
                            .transition(.asymmetric(
                                insertion: .push(from: .top).combined(with: .opacity),
                                removal:   .push(from: .bottom).combined(with: .opacity)
                            ))
                    }

                    // Phase content
                    Group {
                        switch phase {
                        case .idle:
                            idleContent(geo: geo)
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
                                .id("idle")
                        case .searching:
                            searchingContent
                                .transition(.opacity)
                                .id("searching")
                        case .results:
                            resultsContent
                                .transition(.opacity)
                                .id("results")
                        }
                    }
                    .animation(.spring(response: 0.48, dampingFraction: 0.86), value: phase)
                }
            }
        }
    }

    // MARK: - Ambient glow

    private func ambientGlow(geo: GeometryProxy) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.sewnGold.opacity(0.13), .clear],
                    center: .center, startRadius: 0, endRadius: 300
                )
            )
            .frame(width: 600, height: 600)
            .position(x: geo.size.width / 2, y: geo.size.height * 0.22)
            .opacity(phase == .idle ? 1.0 : 0.3)
            .animation(.easeInOut(duration: 1.2), value: phase)
            .allowsHitTesting(false)
    }

    // MARK: - Idle landing

    private func idleContent(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 36) {
                // Logo cluster with orbit rings
                ZStack {
                    DatabaseOrbitRings(iconSize: 96)
                    DatabaseSpinningIcon(size: 96, cornerRadius: 24)
                }

                // Search bar
                VStack(spacing: 14) {
                    SearchBar(query: $query, loading: false, compact: false) {
                        submitSearch()
                    }
                    .frame(maxWidth: min(560, geo.size.width - 48))

                    Text("See beyond the surface")
                        .font(.sewnSerif(13, italic: true))
                        .foregroundStyle(Color.sewnInk.opacity(0.35))
                        .tracking(0.4)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Searching state

    private var searchingContent: some View {
        VStack(spacing: 22) {
            Spacer()

            DatabaseSpinningIcon(size: 44, cornerRadius: 11, opacity: 0.85)

            Text("Searching…")
                .font(.sewnSerif(15, italic: true))
                .foregroundStyle(Color.sewnInk.opacity(0.35))
                .tracking(0.8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private var resultsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = appState.searchError {
                    errorBanner(error)
                        .padding(.horizontal, 24)
                        .padding(.top, 32)
                        .padding(.bottom, 8)
                } else {
                    // Count header
                    HStack {
                        Text(
                            "\(appState.searchResults.count) result\(appState.searchResults.count == 1 ? "" : "s")  \u{00B7}  \u{201C}\(appState.lastQuery)\u{201D}"
                        )
                        .font(.sewnSans(10))
                        .foregroundStyle(Color.sewnInk.opacity(0.35))
                        .tracking(1.4)
                        .textCase(.uppercase)

                        Spacer()

                        // Clear results
                        Button {
                            query = ""
                            appState.clearSearch()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.sewnInk.opacity(0.30))
                        }
                        .buttonStyle(.plain)
                        .help("Clear results")
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 32)
                    .padding(.bottom, 24)

                    // Cards
                    VStack(spacing: 14) {
                        ForEach(Array(appState.searchResults.enumerated()), id: \.element.id) { i, result in
                            SearchResultCard(result: result, index: i)
                                .padding(.horizontal, 24)
                        }
                    }
                    .padding(.bottom, 80)
                }
            }
        }
    }

    // MARK: - Compact header (results / searching)

    private var compactHeader: some View {
        HStack(spacing: 16) {
            // Logo + wordmark — tap to return to idle
            Button {
                query = ""
                appState.clearSearch()
            } label: {
                HStack(spacing: 9) {
                    DatabaseSpinningIcon(size: 30, cornerRadius: 7)
                    Text("Database")
                        .font(.sewnSerif(20, italic: true))
                        .foregroundStyle(Color.sewnInk)
                }
            }
            .buttonStyle(.plain)
            .opacity(0.90)

            // Search bar (compact)
            SearchBar(query: $query, loading: appState.isSearching, compact: true) {
                submitSearch()
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.sewnBorder)
                .frame(height: 1)
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.sewnError)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("Search failed")
                    .font(.sewnSans(12, weight: .medium))
                    .foregroundStyle(Color.sewnInk.opacity(0.75))
                Text(message)
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk.opacity(0.50))
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(16)
        .background(Color.sewnError.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.sewnError.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func submitSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task { await appState.search(query: q) }
    }
}
