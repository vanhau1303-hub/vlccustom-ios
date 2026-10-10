import StoreKit
import SwiftUI

/// "LAN Player Pro": one purchase (non-consumable, StoreKit 2) that removes the ads and unlocks the extras — AI
/// subtitles, finding subtitles online, background and moving thumbnails, sound with the screen locked.
///
/// The unlock is cached in UserDefaults so the app knows it at once on launch (and off the main thread, see
/// `unlocked`); the App Store's own record (`Transaction.currentEntitlements`) confirms or withdraws it each launch.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()
    static let productID = "com.vanhau1303.lanplayer.pro"
    private static let cacheKey = "pro_unlocked"
    private static let testKey = "pro_test_unlocked"

    /// Where a paywall was asked for: the screen that shows it (a sheet can only be shown by the topmost screen —
    /// the main screens, the player, or the subtitle sheet over the player).
    enum Context { case main, player, subtitleSheet }

    struct PaywallRequest: Identifiable {
        let id = UUID()
        let feature: String
        let context: Context
    }

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    @Published var message: String?
    @Published var paywall: PaywallRequest?

    private var updates: Task<Void, Never>?

    /// Pro, readable from any thread (thumbnail, playback and background code is not on the main actor).
    nonisolated static var unlocked: Bool {
        UserDefaults.standard.bool(forKey: cacheKey) || UserDefaults.standard.bool(forKey: testKey)
    }

    private init() {
        isPro = Self.unlocked
        updates = Task { [weak self] in await self?.listenForTransactions() }
        Task { [weak self] in
            await self?.refresh()
            await self?.loadProduct()
        }
    }

    /// Shows the paywall for `feature` unless Pro is already unlocked. True when the feature may be used.
    @discardableResult
    func require(_ feature: String, in context: Context = .main) -> Bool {
        if isPro { return true }
        paywall = PaywallRequest(feature: feature, context: context)
        return false
    }

    func loadProduct() async {
        guard product == nil else { return }
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            PlaybackDiagnostics.append("pro: products failed — \(error.localizedDescription)")
        }
    }

    /// What the App Store says this Apple ID owns.
    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        setOwned(owned)
    }

    func purchase() async {
        message = nil
        await loadProduct()
        guard let product else {
            message = "Chưa lấy được thông tin bản Pro từ App Store. Kiểm tra kết nối mạng rồi thử lại."
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = "Apple không xác minh được giao dịch này."
                    return
                }
                await transaction.finish()
                setOwned(true)
                paywall = nil
            case .pending:
                message = "Giao dịch đang chờ duyệt (ví dụ cần người quản lý gia đình đồng ý). Bản Pro sẽ mở khi được duyệt."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "Không mua được: \(error.localizedDescription)"
        }
    }

    /// "Khôi phục giao dịch": the App Store's purchases for this Apple ID (a new phone, the app reinstalled).
    func restore() async {
        message = nil
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
        } catch {
            message = "Không kết nối được App Store: \(error.localizedDescription)"
            return
        }
        await refresh()
        if isPro {
            message = "Đã khôi phục bản Pro."
            paywall = nil
        } else {
            message = "Apple ID này chưa mua bản Pro."
        }
    }

    /// Sideloaded test builds only (no App Store there to buy from): Pro on / off by hand.
    func setTestUnlock(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.testKey)
        apply()
    }

    var testUnlocked: Bool { UserDefaults.standard.bool(forKey: Self.testKey) }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result else { continue }
            await transaction.finish()
            if transaction.productID == Self.productID { setOwned(transaction.revocationDate == nil) }
        }
    }

    private func setOwned(_ owned: Bool) {
        UserDefaults.standard.set(owned, forKey: Self.cacheKey)
        apply()
    }

    private func apply() {
        let now = Self.unlocked
        guard now != isPro else { return }
        isPro = now
        PlaybackDiagnostics.append("pro: \(now ? "unlocked" : "locked")")
        AdsManager.shared.proChanged()
        if now { ThumbnailBackfill.shared.startAll() }
    }
}

/// What Pro brings, for the paywall.
private let proFeatures: [(icon: String, title: String, detail: String)] = [
    ("nosign", "Không quảng cáo", "Không còn quảng cáo ở bất kỳ màn hình nào."),
    ("waveform", "Phụ đề AI", "Nhận dạng lời nói ngay trên máy và dịch sang tiếng Việt (Apple hoặc Claude)."),
    ("magnifyingglass", "Tìm phụ đề trên mạng", "Tìm và tải phụ đề từ OpenSubtitles, tự dịch nếu khác tiếng Việt."),
    ("square.stack.3d.down.right.fill", "Thumbnail nền & thumbnail động", "Tự tạo sẵn thumbnail cho các thư mục đã xem, xem trước 6 cảnh của video."),
    ("lock.iphone", "Nghe khi khoá màn hình", "Khoá máy vẫn nghe tiếp tiếng của video, điều khiển ở màn hình khoá."),
]

/// The paywall: what Pro brings, the price, buy, restore.
struct ProPaywallView: View {
    let feature: String?
    @ObservedObject private var store = ProStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.yellow.gradient)
                        Text("LAN Player Pro").font(.title2.weight(.bold))
                        if let feature, !feature.isEmpty {
                            Text("\"\(feature)\" có trong bản Pro.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Text("Mua một lần, dùng mãi — không phải thuê bao.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(proFeatures, id: \.title) { item in
                        HStack(alignment: .top, spacing: 12) {
                            SettingsIcon(systemName: item.icon, color: AppTheme.shared.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline.weight(.semibold))
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    if store.isPro {
                        Label("Đã mở khoá bản Pro — cảm ơn anh/chị!", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            HStack {
                                Spacer()
                                if store.busy { ProgressView().tint(.white) }
                                Text(store.product.map { "Mua Pro — \($0.displayPrice)" } ?? "Mua Pro")
                                    .font(.headline)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.busy)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        Button("Khôi phục giao dịch đã mua") {
                            Task { await store.restore() }
                        }
                        .disabled(store.busy)
                    }
                    if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Thanh toán một lần qua tài khoản Apple của bạn. Đã mua trên một máy thì dùng được trên mọi iPhone cùng Apple ID (bấm \"Khôi phục giao dịch\").")
                        HStack(spacing: 16) {
                            Link("Chính sách quyền riêng tư", destination: AboutView.privacyPolicyURL)
                            Link("Điều khoản sử dụng", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        }
                    }
                }
            }
            .navigationTitle("Bản Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
            }
            .task { await store.loadProduct() }
        }
    }
}

extension View {
    /// Presents the paywall asked for in this `context` (`ProStore.require`).
    func proPaywall(_ context: ProStore.Context) -> some View {
        modifier(ProPaywallPresenter(context: context))
    }
}

private struct ProPaywallPresenter: ViewModifier {
    let context: ProStore.Context
    @ObservedObject private var store = ProStore.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { store.paywall?.context == context ? store.paywall : nil },
            set: { if $0 == nil { store.paywall = nil } }
        )) { request in
            ProPaywallView(feature: request.feature)
        }
    }
}

/// A row in Cài đặt for a Pro switch: the toggle itself when unlocked, otherwise the same row opening the paywall.
struct ProToggle<RowLabel: View>: View {
    let feature: String
    @Binding var isOn: Bool
    @ViewBuilder let label: () -> RowLabel
    @ObservedObject private var store = ProStore.shared

    var body: some View {
        if store.isPro {
            Toggle(isOn: $isOn, label: label)
        } else {
            Button { store.require(feature) } label: {
                HStack {
                    label()
                    Spacer()
                    Text("Pro").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.gradient))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
