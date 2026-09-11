import SwiftUI

struct SearchBar: View {
    @Binding var query: String
    let loading: Bool
    let compact: Bool
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    init(query: Binding<String>, loading: Bool, compact: Bool = false, onSubmit: @escaping () -> Void) {
        self._query = query
        self.loading = loading
        self.compact = compact
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            // Search icon
            Image(systemName: "magnifyingglass")
                .font(.system(size: compact ? 14 : 17, weight: .light))
                .foregroundStyle(focused ? Color.sewnGold : Color.sewnInk.opacity(0.35))
                .animation(.easeInOut(duration: 0.2), value: focused)

            // Text input
            TextField("Search the world…", text: $query)
                .textFieldStyle(.plain)
                .font(.sewnSerif(compact ? 15 : 19, weight: .light, italic: true))
                .foregroundStyle(Color.sewnInk)
                .focused($focused)
                .onSubmit { submitQuery() }

            // Trailing indicator
            Group {
                if loading {
                    ProgressView()
                        .scaleEffect(0.75)
                        .tint(Color.sewnGold)
                        .frame(width: 22, height: 22)
                } else if !query.isEmpty {
                    submitButton
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: query.isEmpty)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: loading)
        }
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.vertical, compact ? 9 : 14)
        .background(
            Capsule()
                .fill(focused ? Color.white.opacity(0.96) : Color.white.opacity(0.62))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            focused ? Color.sewnGold.opacity(0.70) : Color.sewnBorder,
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: focused ? Color.sewnGold.opacity(0.15) : Color.sewnInk.opacity(0.07),
                    radius: focused ? 10 : 4, x: 0, y: focused ? 3 : 2
                )
        )
        .animation(.easeInOut(duration: 0.2), value: focused)
    }

    private var submitButton: some View {
        Button(action: submitQuery) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.sewnGold, Color.sewnGold.opacity(0.70)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.sewnGold.opacity(0.30), radius: 4, x: 0, y: 2)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    private func submitQuery() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        focused = false
        onSubmit()
    }
}
