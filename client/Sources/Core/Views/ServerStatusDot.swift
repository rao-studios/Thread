import SwiftUI

// MARK: - Server status dot

struct ServerStatusDot: View {
    let reachable: Bool?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(dotLabel)
                .font(.sewnSans(10))
                .foregroundStyle(Color.sewnInk.opacity(0.35))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.sewnFill)
        .clipShape(Capsule())
    }

    private var dotColor: Color {
        switch reachable {
        case .some(true):  return Color(red: 0.30, green: 0.69, blue: 0.31)
        case .some(false): return Color.sewnError
        case .none:        return Color.sewnInk.opacity(0.25)
        }
    }

    private var dotLabel: String {
        switch reachable {
        case .some(true):  return "online"
        case .some(false): return "offline"
        case .none:        return "checking"
        }
    }
}
