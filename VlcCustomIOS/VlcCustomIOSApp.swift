import SwiftUI
import UIKit

@main
struct VlcCustomIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        PlaybackDiagnostics.start()
        WhisperEngine.removeUnusedModels()
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

/// Tapping anywhere outside a text field closes the keyboard (search boxes, login and server fields...) — one tap
/// recognizer on the window, which never swallows the tap itself, so buttons and rows still work as usual.
final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()
    private weak var window: UIWindow?

    func install() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) ?? ($0 as? UIWindowScene)?.windows.first })
            .first, window !== self.window else { return }
        self.window = window
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        recognizer.view?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Taps inside a text field place the cursor as usual.
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView || current is UISearchBar { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
