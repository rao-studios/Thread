import SwiftUI

// MARK: - File type icon (mimics Finder-style document icon)

struct FileTypeIcon: View {
    let name: String

    private var ext: String { URL(fileURLWithPath: name).pathExtension.lowercased() }

    private var style: (Color, String) {
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic":
            return (Color(red: 0.56, green: 0.49, blue: 0.32), "IMG")
        case "pdf":
            return (Color(red: 0.84, green: 0.36, blue: 0.29), "PDF")
        case "doc", "docx":
            return (Color(red: 0.22, green: 0.44, blue: 0.65), "DOC")
        case "md", "markdown":
            return (Color(red: 0.65, green: 0.40, blue: 0.55), "MD")
        case "json", "xml", "csv":
            return (Color(red: 0.38, green: 0.55, blue: 0.38), "DAT")
        case "txt", "text":
            return (Color.sewnInk.opacity(0.55), "TXT")
        case "html", "htm":
            return (Color(red: 0.91, green: 0.42, blue: 0.13), "HTML")
        case "swift":
            return (Color(red: 0.98, green: 0.44, blue: 0.20), "SWF")
        case "py":
            return (Color(red: 0.24, green: 0.52, blue: 0.78), "PY")
        case "js", "ts":
            return (Color(red: 0.95, green: 0.77, blue: 0.15), "JS")
        default:
            return (Color.sewnInk.opacity(0.28), "FILE")
        }
    }

    var body: some View {
        let (color, label) = style
        ZStack(alignment: .topTrailing) {
            // Document body
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.sewnInk.opacity(0.10), lineWidth: 1)
                )
                .frame(width: 40, height: 50)

            // Folded corner (triangle cutout)
            Path { p in
                p.move(to: CGPoint(x: 27, y: 0))
                p.addLine(to: CGPoint(x: 40, y: 0))
                p.addLine(to: CGPoint(x: 40, y: 13))
                p.closeSubpath()
            }
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: 40, height: 50)

            Path { p in
                p.move(to: CGPoint(x: 27, y: 0))
                p.addLine(to: CGPoint(x: 40, y: 13))
                p.addLine(to: CGPoint(x: 27, y: 13))
                p.closeSubpath()
            }
            .stroke(Color.sewnInk.opacity(0.10), lineWidth: 0.5)
            .frame(width: 40, height: 50)

            // File type label
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(color)
                .frame(width: 40, height: 50)
                .offset(y: 5)
        }
        .frame(width: 40, height: 50)
    }
}

// MARK: - Indexed document card

struct DocumentFileCard: View {
    let doc: DatabaseDocument
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 10) {
            FileTypeIcon(name: doc.name)
                .opacity(isHovered ? 1.0 : 0.88)
                .animation(.easeInOut(duration: 0.15), value: isHovered)

            VStack(spacing: 4) {
                Text(doc.name)
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 96)

                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(red: 0.30, green: 0.69, blue: 0.31))
                        .frame(width: 5, height: 5)
                    Text("indexed")
                        .font(.sewnSans(10))
                        .foregroundStyle(Color.sewnInk.opacity(0.30))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .frame(width: 120)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.sewnFill : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isHovered ? Color.sewnBorder : Color.clear, lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Uploading file card

struct UploadingFileCard: View {
    let file: UploadingFile

    private var isError: Bool { file.status.isError }
    private var isDone:  Bool { file.status.isDone }

    private var accentColor: Color { isError ? Color.sewnError : Color.sewnGold }

    var body: some View {
        VStack(spacing: 10) {
            FileTypeIcon(name: file.name)

            VStack(spacing: 4) {
                Text(file.name)
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 96)

                Text(file.status.label)
                    .font(.sewnSans(10).italic())
                    .foregroundStyle(accentColor.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 96)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .frame(width: 120)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accentColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(accentColor.opacity(0.28), lineWidth: 1)
                )
        )
        .opacity(isDone ? 0.45 : 1.0)
        .animation(.easeInOut(duration: 0.3), value: isDone)
    }
}

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
