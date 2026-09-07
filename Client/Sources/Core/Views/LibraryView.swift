import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isDragTargeted = false
    @State private var showFilePicker = false
    @State private var showSettings = false

    private var hasItems: Bool {
        !appState.uploadingFiles.isEmpty || !appState.documents.isEmpty
    }

    var body: some View {
        ZStack {
            Color.sewnBG.ignoresSafeArea()

            VStack(spacing: 0) {
                toolbar
                Divider()
                    .background(Color.sewnBorder)

                if hasItems {
                    fileGrid
                } else {
                    emptyState
                }
            }

            if isDragTargeted {
                dropOverlay
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [
                .pdf, .rtf, .rtfd,
                .plainText, .utf8PlainText,
                .html,
                .json, .commaSeparatedText,
                .sourceCode, .data, .item,
            ],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                appState.uploadFiles(urls: urls)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Logo mark
            DatabaseSpinningIcon(size: 22, cornerRadius: 5)

            Text("Library")
                .font(.sewnSerif(15, weight: .medium))
                .foregroundStyle(Color.sewnInk)

            Spacer()

            ServerStatusDot(reachable: appState.serverReachable)

            // Refresh health
            Button {
                Task { await appState.checkHealth() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help("Refresh connection")

            Divider()
                .frame(height: 16)
                .background(Color.sewnBorder)

            // Upload
            Button {
                showFilePicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12))
                    Text("Upload")
                        .font(.sewnSans(12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.sewnGold)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            // Settings gear
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.sewnInk.opacity(0.30))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    // MARK: - File grid

    private var fileGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 8)],
                spacing: 8
            ) {
                ForEach(appState.uploadingFiles) { file in
                    UploadingFileCard(file: file)
                }
                ForEach(appState.documents) { doc in
                    DocumentFileCard(doc: doc)
                }
            }
            .padding(24)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.documents.count)
            .animation(.easeInOut, value: appState.uploadingFiles.count)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "folder")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(Color.sewnGold.opacity(0.30))

            VStack(spacing: 8) {
                Text("No documents yet")
                    .font(.sewnSerif(19))
                    .foregroundStyle(Color.sewnInk.opacity(0.55))

                Text("Drag files here or click Upload\nto embed documents for search")
                    .font(.sewnSans(12))
                    .foregroundStyle(Color.sewnInk.opacity(0.30))
                    .multilineTextAlignment(.center)
            }

            Button {
                showFilePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle")
                    Text("Upload Files")
                }
                .font(.sewnSans(13, weight: .medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Color.sewnGold)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Spacer()

            Text("Supported: txt · md · pdf · html · json · csv · rtf · code")
                .font(.sewnSans(10))
                .foregroundStyle(Color.sewnInk.opacity(0.20))
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - Drop overlay

    private var dropOverlay: some View {
        ZStack {
            Color.sewnGold.opacity(0.04)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    Color.sewnGold.opacity(0.65),
                    style: StrokeStyle(lineWidth: 2, dash: [9, 5])
                )
                .padding(14)

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(Color.sewnGold.opacity(0.80))

                Text("Drop to upload")
                    .font(.sewnSerif(22))
                    .foregroundStyle(Color.sewnGold.opacity(0.85))

                Text("Files will be processed and embedded")
                    .font(.sewnSans(12))
                    .foregroundStyle(Color.sewnGold.opacity(0.50))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Drop handler

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard
                    let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                DispatchQueue.main.async {
                    appState.uploadFiles(urls: [url])
                }
            }
        }
    }
}
