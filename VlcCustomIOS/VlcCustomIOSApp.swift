import SwiftUI

@main
struct VlcCustomIOSApp: App {
    init() {
        PlaybackDiagnostics.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
