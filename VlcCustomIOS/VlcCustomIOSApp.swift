import SwiftUI
import UIKit

@main
struct VlcCustomIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        PlaybackDiagnostics.start()
        // Suspended apps are killed first by how much memory they hold: drop what can be rebuilt (decoded
        // thumbnails and pictures) on the way to the background, and on a memory warning.
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                FullImageCache.clear()
                Task { await ThumbnailService.shared.clearMemory() }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Only here to answer iOS's "which orientations are allowed right now" — the hook `OrientationLock` needs for the
/// player's rotate button to actually hold landscape/portrait instead of snapping back with the device.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

enum OrientationLock {
    static private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown

    /// Forces the interface into `orientation` and keeps it there until `unlock()`.
    static func lock(_ orientation: UIInterfaceOrientationMask) {
        mask = orientation
        apply(orientation)
    }

    /// Back to following the device (portrait + both landscapes).
    static func unlock() {
        guard mask != .allButUpsideDown else { return }
        mask = .allButUpsideDown
        apply(.allButUpsideDown)
    }

    private static func apply(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        // Every controller up the presentation chain (the player is a fullScreenCover) must re-ask for the mask.
        var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            PlaybackDiagnostics.append("orientation: \(error.localizedDescription)")
        }
    }
}
