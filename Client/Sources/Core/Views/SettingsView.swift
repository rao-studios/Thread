import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var threadURL  = ""
    @State private var ownerId   = ""
    @State private var email     = ""
    @State private var password  = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                DatabaseSpinningIcon(size: 28, cornerRadius: 7)
                Text("Settings")
                    .font(.sewnSerif(20, weight: .medium))
                    .foregroundStyle(Color.sewnInk)
            }
            .padding(.bottom, 28)

            // Database (mothership) URL
            fieldGroup(
                label: "Database URL",
                hint: "Mothership — handles search and library (default :8080).",
                content: {
                    TextField("http://127.0.0.1:8080", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.sewnMono(12))
                }
            )

            Spacer().frame(height: 18)

            // Thread URL
            fieldGroup(
                label: "Thread URL",
                hint: "Vector node — handles embedding and indexing (default :8081).",
                content: {
                    TextField("http://127.0.0.1:8081", text: $threadURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.sewnMono(12))
                }
            )

            Spacer().frame(height: 18)

            // Owner ID
            fieldGroup(
                label: "Owner ID",
                hint: "Documents are indexed under this ID. Sign in below to use your account ID.",
                content: {
                    TextField("database-demo", text: $ownerId)
                        .textFieldStyle(.roundedBorder)
                        .font(.sewnMono(12))
                        .disabled(appState.isSignedIn)
                        .opacity(appState.isSignedIn ? 0.5 : 1)
                }
            )

            Spacer().frame(height: 18)

            // Sewn Account sign-in
            signInSection

            Spacer()

            Divider().padding(.bottom, 16)

            // Buttons
            HStack {
                // Server status
                ServerStatusDot(reachable: appState.serverReachable)
                Button("Test Connection") {
                    appState.serverURL = serverURL
                    appState.threadURL  = threadURL
                    Task { await appState.checkHealth() }
                }
                .font(.sewnSans(12))
                .buttonStyle(.plain)
                .foregroundStyle(Color.sewnGold)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    appState.serverURL = serverURL
                    appState.threadURL  = threadURL
                    if !appState.isSignedIn { appState.ownerId = ownerId }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.sewnGold)
            }
        }
        .padding(28)
        .frame(width: 420, height: 500)
        .background(Color.sewnBG)
        .onAppear {
            serverURL = appState.serverURL
            threadURL  = appState.threadURL
            ownerId   = appState.ownerId
        }
    }

    @ViewBuilder
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sewn Account")
                .font(.sewnSans(12, weight: .medium))
                .foregroundStyle(Color.sewnInk.opacity(0.60))

            if appState.isSignedIn {
                HStack {
                    Text("Signed in as \(appState.ownerId)")
                        .font(.sewnMono(12))
                        .foregroundStyle(Color.sewnInk.opacity(0.70))
                    Spacer()
                    Button("Sign Out") {
                        appState.signOut()
                        ownerId = appState.ownerId
                    }
                    .font(.sewnSans(12))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.sewnGold)
                }
            } else {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .font(.sewnMono(12))
                    .textContentType(.emailAddress)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.sewnMono(12))

                HStack {
                    if appState.isSigningIn {
                        ProgressView().scaleEffect(0.7)
                    }
                    Button(appState.isSigningIn ? "Signing in…" : "Sign In") {
                        appState.serverURL = serverURL
                        Task {
                            await appState.signIn(email: email, password: password)
                            ownerId = appState.ownerId
                        }
                    }
                    .font(.sewnSans(12))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.sewnGold)
                    .disabled(email.isEmpty || password.isEmpty || appState.isSigningIn)

                    if let err = appState.signInError {
                        Spacer()
                        Text(err)
                            .font(.sewnSans(11))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                Text("Sign in to track costs and index under your account ID.")
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk.opacity(0.30))
            }
        }
    }

    @ViewBuilder
    private func fieldGroup<Content: View>(
        label: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.sewnSans(12, weight: .medium))
                .foregroundStyle(Color.sewnInk.opacity(0.60))
            content()
            Text(hint)
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.30))
        }
    }
}
