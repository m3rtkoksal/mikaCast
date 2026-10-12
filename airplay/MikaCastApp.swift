import SwiftUI

@main
struct MikaCastApp: App {
    init() {
        FFmpegTranscoder.purgeOrphanedTemps()
    }

    var body: some Scene {
        WindowGroup("MikaCast") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 560, height: 620)
    }
}
