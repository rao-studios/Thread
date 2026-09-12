import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var mode: AppMode = .search
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            SidebarView(mode: $mode, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.sewnBG)
        }
        .environmentObject(appState)
        .task { await appState.checkHealth() }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(appState)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch mode {
        case .search:    SearchView()
        case .index:     IndexView()
        case .graph:     GraphView()
        case .library:   LibraryView()
        case .store:     StoreView()
        case .inspector: InspectorView()
        }
    }
}
