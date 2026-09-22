import Foundation

/// JSON-backed store for named playlists. Two independent instances are used — one for video, one for music — so
/// they never mix, the same way the SMB server list and favorites are each their own `UserDefaults` key.
final class PlaylistStore {
    static let video = PlaylistStore(key: "video_playlists")
    static let music = PlaylistStore(key: "music_playlists")

    private let key: String
    private init(key: String) { self.key = key }

    func load() -> [Playlist] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let playlists = try? JSONDecoder().decode([Playlist].self, from: data) else { return [] }
        return playlists
    }

    private func save(_ playlists: [Playlist]) {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    @discardableResult
    func create(name: String) -> Playlist {
        var playlists = load()
        let playlist = Playlist(id: UUID().uuidString, name: name, items: [])
        playlists.append(playlist)
        save(playlists)
        return playlist
    }

    func rename(_ id: String, to name: String) {
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        save(playlists)
    }

    func delete(_ id: String) {
        save(load().filter { $0.id != id })
    }

    func addItem(_ item: PlaylistItem, to playlistId: String) {
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        if !playlists[index].items.contains(where: { $0.uri == item.uri }) {
            playlists[index].items.append(item)
        }
        save(playlists)
    }

    func removeItem(_ uri: String, from playlistId: String) {
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].items.removeAll { $0.uri == uri }
        save(playlists)
    }
}
