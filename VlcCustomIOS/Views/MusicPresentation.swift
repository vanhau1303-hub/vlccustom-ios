import SwiftUI

/// Whether the music player is expanded (full screen) or collapsed into the mini bar, app-wide — so tapping a song
/// anywhere (Mạng, a Yêu thích folder, the libraries in Cài đặt...) opens the player straight away, and swiping it
/// down collapses it to the mini bar of whatever screen is on top.
///
/// Screens that can host the player register with `.musicPlayerHost()`. Sheets stack on top of the tab view, so
/// only the most recently shown host displays the mini bar / presents the player (a presentation from a covered
/// screen would not show at all).
final class MusicUI: ObservableObject {
    static let shared = MusicUI()

    @Published private(set) var expanded = false
    /// The host that presented the current expansion — fixed until collapsed, since presenting a full-screen cover
    /// makes its host "disappear" underneath it.
    @Published private(set) var presenter: UUID?
    @Published private(set) var topHost: UUID?
    private var hosts: [UUID] = []

    private init() {}

    func expand() {
        presenter = topHost
        expanded = true
    }

    func collapse() {
        expanded = false
    }

    fileprivate func register(_ id: UUID) {
        hosts.removeAll { $0 == id }
        hosts.append(id)
        topHost = id
    }

    fileprivate func unregister(_ id: UUID) {
        hosts.removeAll { $0 == id }
        topHost = hosts.last
    }
}

private struct MusicPlayerHost: ViewModifier {
    @State private var id = UUID()
    @ObservedObject private var ui = MusicUI.shared
    @ObservedObject private var queue = MusicQueue.shared

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if queue.current != nil, ui.topHost == id {
                    NowPlayingBar(onTap: { ui.expand() })
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { ui.expanded && ui.presenter == id },
                set: { if !$0 { ui.collapse() } }
            )) {
                MusicPlayerScreen(onClose: { ui.collapse() })
            }
            .onAppear { ui.register(id) }
            .onDisappear { ui.unregister(id) }
    }
}

extension View {
    /// Shows the music mini bar and presents the full music player for this screen (see `MusicUI`).
    func musicPlayerHost() -> some View {
        modifier(MusicPlayerHost())
    }
}
