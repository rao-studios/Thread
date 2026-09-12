import SwiftUI

/// Why these results came back: the entities the query matched in the graph,
/// the edges the one-hop expansion crossed, and how many documents that pulled
/// in beyond the direct vector hits.
///
/// The server has always returned this alongside `/v1/search`; the client used
/// to discard it, which made hybrid retrieval look like plain vector search.
struct SearchGraphCard: View {
    let context: SearchGraphContext
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sewnGold)
                    Text("Graph context")
                        .font(.sewnSans(11, weight: .medium))
                        .foregroundStyle(Color.sewnInk.opacity(0.65))
                    Text(summary)
                        .font(.sewnSans(10.5))
                        .foregroundStyle(Color.sewnInk.opacity(0.35))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.sewnInk.opacity(0.30))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !context.entities.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        label("Matched entities")
                        FlowRow(spacing: 5) {
                            ForEach(context.entities) { entity in
                                chip(entity.name, kind: entity.kind)
                            }
                        }
                    }
                }

                if !context.relationships.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        label("Expansion edges")
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(context.relationships) { edge in
                                HStack(spacing: 5) {
                                    Text(edge.subject)
                                        .foregroundStyle(Color.sewnInk.opacity(0.70))
                                    Text(edge.predicate)
                                        .foregroundStyle(Color.sewnGold.opacity(0.85))
                                    Text(edge.object)
                                        .foregroundStyle(Color.sewnInk.opacity(0.70))
                                    if edge.weight > 1 {
                                        Text("×\(edge.weight)")
                                            .foregroundStyle(Color.sewnInk.opacity(0.35))
                                    }
                                }
                                .font(.sewnSans(11))
                            }
                        }
                    }
                }

                if context.expandedDocuments > 0 {
                    Text("\(context.expandedDocuments) document\(context.expandedDocuments == 1 ? "" : "s") reached through the graph rather than by distance alone. These are scored with a penalty, so a graph-reached hit never outranks an equally close direct one.")
                        .font(.sewnSans(10.5))
                        .foregroundStyle(Color.sewnInk.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(13)
        .background(Color.sewnCard)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.sewnBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var summary: String {
        var parts: [String] = []
        if !context.entities.isEmpty { parts.append("\(context.entities.count) entities") }
        if !context.relationships.isEmpty { parts.append("\(context.relationships.count) edges") }
        if context.expandedDocuments > 0 { parts.append("+\(context.expandedDocuments) docs") }
        return parts.joined(separator: " · ")
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.sewnSans(8.5))
            .tracking(1.2)
            .foregroundStyle(Color.sewnInk.opacity(0.32))
    }

    private func chip(_ name: String, kind: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(EntityPalette.color(for: kind).opacity(0.8))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.sewnSans(10.5))
                .foregroundStyle(Color.sewnInk.opacity(0.70))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.sewnFill)
        .clipShape(Capsule())
    }
}

/// Minimal wrapping layout — entity chips need to wrap and `LazyVGrid` would
/// force a fixed column width onto variable-length names.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
