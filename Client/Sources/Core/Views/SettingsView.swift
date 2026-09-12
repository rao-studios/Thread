import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var threadURL = ""
    @State private var ownerId = ""
    @State private var groupId = ""
    @State private var dataDirectory = ""

    @State private var showAccount = false
    @State private var showDanger = false
    @State private var serverURL = ""
    @State private var email = ""
    @State private var password = ""

    @State private var clearConfirmation = ""
    @State private var clearing = false
    @State private var clearResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DatabaseSpinningIcon(size: 26, cornerRadius: 6)
                Text("Settings")
                    .font(.sewnSerif(19, weight: .medium))
                    .foregroundStyle(Color.sewnInk)
            }
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fieldGroup("Thread URL",
                               hint: "The node this client talks to. Default port is 8081.") {
                        TextField("http://127.0.0.1:8081", text: $threadURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.sewnMono(12))
                    }

                    fieldGroup("Owner ID",
                               hint: "Thread has no authentication — this is the only identity there is.") {
                        TextField("database-demo", text: $ownerId)
                            .textFieldStyle(.roundedBorder)
                            .font(.sewnMono(12))
                            .disabled(appState.isSignedIn)
                            .opacity(appState.isSignedIn ? 0.5 : 1)
                    }

                    fieldGroup("Group ID",
                               hint: "Documents indexed from this client are assigned to this group.") {
                        TextField("demo-group", text: $groupId)
                            .textFieldStyle(.roundedBorder)
                            .font(.sewnMono(12))
                    }

                    fieldGroup("Data directory",
                               hint: "Read-only. Where the node keeps its state — empty means ~/Documents/thread-db.") {
                        HStack(spacing: 7) {
                            TextField(StoreReader.defaultDirectory.path, text: $dataDirectory)
                                .textFieldStyle(.roundedBorder)
                                .font(.sewnMono(11))
                            Button("Browse…") { chooseDirectory() }
                                .font(.sewnSans(11.5))
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.sewnGold)
                        }
                    }

                    Divider().background(Color.sewnBorder)

                    // The mothership is optional and unrelated to Thread itself,
                    // so it no longer sits on the main path.
                    DisclosureGroup(isExpanded: $showAccount) {
                        accountSection.padding(.top, 10)
                    } label: {
                        Text("Sewn account (optional)")
                            .font(.sewnSans(12, weight: .medium))
                            .foregroundStyle(Color.sewnInk.opacity(0.60))
                    }

                    DisclosureGroup(isExpanded: $showDanger) {
                        dangerSection.padding(.top, 10)
                    } label: {
                        Text("Destructive")
                            .font(.sewnSans(12, weight: .medium))
                            .foregroundStyle(Color.sewnError.opacity(0.75))
                    }
                }
                .padding(.trailing, 2)
            }

            Divider().padding(.vertical, 14)

            HStack(spacing: 10) {
                ServerStatusDot(reachable: appState.serverReachable)

                Button("Test connection") {
                    apply()
                    Task { await appState.checkHealth() }
                }
                .font(.sewnSans(12))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnGold)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.sewnGold)
            }
        }
        .padding(26)
        .frame(width: 470, height: 580)
        .background(Color.sewnBG)
        .onAppear {
            threadURL = appState.threadURL
            ownerId = appState.ownerId
            groupId = appState.groupId
            dataDirectory = appState.dataDirectory
            serverURL = appState.serverURL
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Only used to borrow an account id as the owner. Thread itself never sees it, and node health does not depend on it.")
                .font(.sewnSans(10.5))
                .foregroundStyle(Color.sewnInk.opacity(0.30))
                .fixedSize(horizontal: false, vertical: true)

            TextField("http://127.0.0.1:8080", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .font(.sewnMono(11))

            if appState.isSignedIn {
                HStack {
                    Text("Signed in as \(appState.ownerId)")
                        .font(.sewnMono(11))
                        .foregroundStyle(Color.sewnInk.opacity(0.70))
                    Spacer()
                    Button("Sign out") {
                        appState.signOut()
                        ownerId = appState.ownerId
                    }
                    .font(.sewnSans(11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.sewnGold)
                }
            } else {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .font(.sewnMono(11))
                    .textContentType(.emailAddress)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.sewnMono(11))

                HStack(spacing: 8) {
                    if appState.isSigningIn {
                        ProgressView().scaleEffect(0.5)
                    }
                    Button(appState.isSigningIn ? "Signing in…" : "Sign in") {
                        appState.serverURL = serverURL
                        Task {
                            await appState.signIn(email: email, password: password)
                            ownerId = appState.ownerId
                        }
                    }
                    .font(.sewnSans(11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.sewnGold)
                    .disabled(email.isEmpty || password.isEmpty || appState.isSigningIn)

                    if let error = appState.signInError {
                        Text(error)
                            .font(.sewnSans(10.5))
                            .foregroundStyle(Color.sewnError)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Destructive

    @ViewBuilder
    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Clearing wipes this node's partition table, knowledge graph and registry. Document content files are left on disk because co-located nodes may share them. This cannot be undone.")
                .font(.sewnSans(10.5))
                .foregroundStyle(Color.sewnInk.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                TextField("type CLEAR to confirm", text: $clearConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .font(.sewnMono(11))

                Button(clearing ? "Clearing…" : "Clear node") {
                    Task { await clear() }
                }
                .font(.sewnSans(11.5))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnError)
                .disabled(clearing || clearConfirmation != "CLEAR")
            }

            if let clearResult {
                Text(clearResult)
                    .font(.sewnSans(10.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Single-document deletion is a gRPC-only operation, so there is no
            // honest control for it here.
            Text("Deleting an individual document isn't exposed over HTTP — only this whole-node wipe is.")
                .font(.sewnSans(10))
                .foregroundStyle(Color.sewnInk.opacity(0.28))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func fieldGroup<Content: View>(_ label: String,
                                           hint: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.sewnSans(12, weight: .medium))
                .foregroundStyle(Color.sewnInk.opacity(0.60))
            content()
            Text(hint)
                .font(.sewnSans(10.5))
                .foregroundStyle(Color.sewnInk.opacity(0.30))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func apply() {
        appState.threadURL = threadURL
        appState.serverURL = serverURL
        appState.groupId = groupId
        appState.dataDirectory = dataDirectory
        if !appState.isSignedIn { appState.ownerId = ownerId }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = StoreReader.resolve(dataDirectory)
        panel.prompt = "Choose"
        panel.message = "Pick a Thread data directory (the one holding node-id)."
        if panel.runModal() == .OK, let url = panel.url {
            dataDirectory = url.path
        }
    }

    private func clear() async {
        clearing = true
        clearResult = nil
        apply()
        do {
            let result = try await appState.api.clear()
            clearResult = "Cleared \(result.documents) document(s) and \(result.entities) entit\(result.entities == 1 ? "y" : "ies")."
            clearConfirmation = ""
            appState.clearSearch()
        } catch {
            clearResult = error.localizedDescription
        }
        clearing = false
    }
}
