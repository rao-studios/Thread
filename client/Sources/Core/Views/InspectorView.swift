import SwiftUI
import AppKit

/// The wire log and the extraction-policy editor — the two things that are
/// about the node's behaviour rather than its contents.
struct InspectorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var tab: Tab = .wire

    enum Tab: String, CaseIterable, Identifiable {
        case wire = "Wire"
        case policy = "Policy"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)

            Divider().background(Color.sewnBorder)

            switch tab {
            case .wire:   WireLogView()
            case .policy: PolicyView()
            }
        }
    }
}

// MARK: - Wire log

struct WireLogView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: UUID?

    private var entries: [WireLog.Entry] { appState.wireLog.entries }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
            detail
                .frame(minWidth: 320)
        }
        .onReceive(appState.wireLog.objectWillChange) { _ in }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(entries.count) CALL\(entries.count == 1 ? "" : "S")")
                    .font(.sewnSans(10))
                    .tracking(1.4)
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
                Spacer()
                Button("Clear") { appState.wireLog.clear() }
                    .font(.sewnSans(11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.sewnGold)
                    .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().background(Color.sewnBorder)

            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color.sewnBG)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.sewnInk.opacity(0.18))
            Text("No calls yet")
                .font(.sewnSerif(13, italic: true))
                .foregroundStyle(Color.sewnInk.opacity(0.32))
            Text("Every request the client makes is recorded here.")
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.25))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private func row(_ entry: WireLog.Entry) -> some View {
        let selected = selection == entry.id
        return Button {
            selection = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.method)
                        .font(.sewnMono(9))
                        .foregroundStyle(Color.sewnInk.opacity(0.45))
                    Text(path(entry.url))
                        .font(.sewnMono(11))
                        .foregroundStyle(Color.sewnInk.opacity(0.80))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                    statusBadge(entry)
                }
                HStack(spacing: 6) {
                    Text(entry.started, style: .time)
                        .font(.sewnSans(9.5))
                        .foregroundStyle(Color.sewnInk.opacity(0.28))
                    if let d = entry.duration {
                        Text(format(d))
                            .font(.sewnSans(9.5))
                            .foregroundStyle(Color.sewnInk.opacity(0.28))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(selected ? Color.sewnGold.opacity(0.09) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusBadge(_ entry: WireLog.Entry) -> some View {
        if entry.isInFlight {
            ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
        } else if let status = entry.status {
            Text("\(status)")
                .font(.sewnMono(9.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(entry.isError ? Color.sewnError.opacity(0.12) : Color.sewnGold.opacity(0.14))
                .foregroundStyle(entry.isError ? Color.sewnError : Color.sewnGold)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.sewnError)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = entries.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Text("\(entry.method) \(path(entry.url))")
                            .font(.sewnMono(12.5))
                            .foregroundStyle(Color.sewnInk.opacity(0.85))
                        Spacer()
                        Button {
                            copy(entry.curl)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                Text("Copy as curl")
                                    .font(.sewnSans(11))
                            }
                            .foregroundStyle(Color.sewnGold)
                        }
                        .buttonStyle(.plain)
                    }

                    if let failure = entry.failure {
                        section("Error", body: failure, mono: false, tint: Color.sewnError)
                    }

                    if let request = entry.requestBody {
                        section("Request", body: request)
                    }

                    if let response = entry.responseBody {
                        section("Response", body: response)
                    } else if entry.status != nil {
                        // A 500 from Hummingbird has an empty body; say so rather
                        // than showing a blank panel that looks like a client bug.
                        section("Response", body: "(empty body)", mono: false)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a call")
                    .font(.sewnSerif(13, italic: true))
                    .foregroundStyle(Color.sewnInk.opacity(0.30))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func section(_ title: String,
                         body: String,
                         mono: Bool = true,
                         tint: Color = Color.sewnInk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.sewnSans(9.5))
                .tracking(1.3)
                .foregroundStyle(Color.sewnInk.opacity(0.32))
            Text(body)
                .font(mono ? .sewnMono(11) : .sewnSans(11.5))
                .foregroundStyle(tint.opacity(0.80))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Color.sewnCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.sewnBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Helpers

    private func path(_ url: String) -> String {
        URL(string: url).map { $0.path.isEmpty ? url : $0.path } ?? url
    }

    private func format(_ seconds: TimeInterval) -> String {
        seconds < 1
            ? "\(Int(seconds * 1000)) ms"
            : String(format: "%.2f s", seconds)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
