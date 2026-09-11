import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        HSplitView {
            LibraryView()
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 520)

            SearchView()
                .frame(minWidth: 440)
        }
        .background(Color.sewnBG)
        .environmentObject(appState)
        .task { await appState.checkHealth() }
    }
}
