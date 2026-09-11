import SwiftUI

struct DatabaseDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 700)
        .windowStyle(.titleBar)
        .commands {
            // Remove New Window from File menu — single-window demo
            CommandGroup(replacing: .newItem) { }
        }
    }
}
