import SwiftUI

@main
struct airplayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 560, height: 620)
    }
}
