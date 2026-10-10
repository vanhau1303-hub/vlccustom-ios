import AppTrackingTransparency
import GoogleMobileAds
import SwiftUI
import UIKit
import UserMessagingPlatform

/// Ads in the free version (Google AdMob); none at all with Pro, and never while a video plays:
/// - a banner at the bottom of the browsing screens (Mạng, Yêu thích);
/// - now and then a full-screen ad when the player is closed — only after at least two minutes of watching, and at
///   most one every ten minutes.
/// Consent first: Google's form where the law asks for it (EEA / UK), then Apple's tracking question, then ads.
/// The ad ids come from the build (`LAN_ADMOB_APP_ID`, `LAN_AD_BANNER_UNIT`, `LAN_AD_INTERSTITIAL_UNIT`): Google's
/// test ids by default, the real ones only in App Store builds.
@MainActor
final class AdsManager: NSObject, ObservableObject {
    static let shared = AdsManager()

    @Published private(set) var canShowAds = false

    private var started = false
    private var interstitial: GADInterstitialAd?
    private var lastInterstitial = Date()

    static var bannerUnit: String { Bundle.main.object(forInfoDictionaryKey: "LANAdBannerUnit") as? String ?? "" }
    static var interstitialUnit: String { Bundle.main.object(forInfoDictionaryKey: "LANAdInterstitialUnit") as? String ?? "" }

    /// Launch (and when Pro is bought or withdrawn): consent, then the SDK, only for the free version.
    func start() {
        guard !ProStore.unlocked, !started else { return }
        started = true
        let parameters = UMPRequestParameters()
        UMPConsentInformation.sharedInstance.requestConsentInfoUpdate(with: parameters) { [weak self] error in
            if let error { PlaybackDiagnostics.append("ads: consent info — \(error.localizedDescription)") }
            Task { @MainActor in
                guard let root = Self.topViewController() else {
                    await self?.afterConsent()
                    return
                }
                UMPConsentForm.loadAndPresentIfRequired(from: root) { error in
                    if let error { PlaybackDiagnostics.append("ads: consent form — \(error.localizedDescription)") }
                    Task { @MainActor in await self?.afterConsent() }
                }
            }
        }
    }

    private func afterConsent() async {
        guard UMPConsentInformation.sharedInstance.canRequestAds, !ProStore.unlocked else { return }
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        GADMobileAds.sharedInstance().start(completionHandler: nil)
        canShowAds = true
        loadInterstitial()
    }

    /// Pro bought: no more ads from now on.
    func proChanged() {
        if ProStore.unlocked {
            canShowAds = false
            interstitial = nil
        } else {
            start()
        }
    }

    private func loadInterstitial() {
        guard !ProStore.unlocked, !Self.interstitialUnit.isEmpty else { return }
        GADInterstitialAd.load(withAdUnitID: Self.interstitialUnit, request: GADRequest()) { [weak self] ad, error in
            if let error { PlaybackDiagnostics.append("ads: interstitial — \(error.localizedDescription)") }
            Task { @MainActor in
                ad?.fullScreenContentDelegate = self
                self?.interstitial = ad
            }
        }
    }

    /// The player closed after `watched` seconds: maybe a full-screen ad, once the player is gone.
    func playerClosed(watched: TimeInterval) {
        guard canShowAds, !ProStore.unlocked, watched >= 120,
              Date().timeIntervalSince(lastInterstitial) >= 600, let ad = interstitial else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, let root = Self.topViewController(), !ProStore.unlocked else { return }
            self.lastInterstitial = Date()
            self.interstitial = nil
            ad.present(fromRootViewController: root)
        }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}

extension AdsManager: GADFullScreenContentDelegate {
    nonisolated func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        Task { @MainActor in self.loadInterstitial() }
    }

    nonisolated func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in self.loadInterstitial() }
    }
}

/// The banner at the bottom of a browsing screen (free version only; nothing at all with Pro).
struct AdBanner: View {
    @ObservedObject private var ads = AdsManager.shared
    @ObservedObject private var pro = ProStore.shared

    var body: some View {
        if ads.canShowAds, !pro.isPro, !AdsManager.bannerUnit.isEmpty {
            BannerAdView()
                .frame(width: 320, height: 50)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.bar)
        }
    }
}

private struct BannerAdView: UIViewRepresentable {
    func makeUIView(context: Context) -> GADBannerView {
        let banner = GADBannerView(adSize: GADAdSizeBanner)
        banner.adUnitID = AdsManager.bannerUnit
        banner.rootViewController = AdsManager.topViewController()
        banner.load(GADRequest())
        return banner
    }

    func updateUIView(_ uiView: GADBannerView, context: Context) {
        if uiView.rootViewController == nil { uiView.rootViewController = AdsManager.topViewController() }
    }
}
