import AVFoundation
import MediaPlayer
import UIKit

/// The iPhone's own output volume (what the hardware buttons change), set from swipe gestures.
///
/// The players used to change libVLC's software volume instead, which only takes effect once the audio libVLC has
/// already buffered has played out — the half-second-plus lag on the volume swipe. The system volume applies
/// immediately. iOS has no public setter for it; the supported way is the slider inside an `MPVolumeView`. A
/// practically invisible one is kept in the key window, which also stops iOS from showing its own volume HUD on top
/// of the app's hint.
enum SystemVolume {
    private static var volumeView: MPVolumeView?

    /// Current volume, 0...1.
    static var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    static func set(_ value: Float) {
        guard let slider = slider() else { return }
        slider.value = min(1, max(0, value))
    }

    private static func slider() -> UISlider? {
        if volumeView?.window == nil {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else { return nil }
            let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
            view.alpha = 0.01
            view.isUserInteractionEnabled = false
            window.addSubview(view)
            volumeView = view
        }
        return volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }
}
