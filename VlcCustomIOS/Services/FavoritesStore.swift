import Foundation

/// JSON-backed store of starred SMB folders, for quick access from a dedicated "Yêu thích" tab instead of
/// reconnecting and navigating by hand every time.
enum FavoritesStore {
    private static let key = "favorite_folders"

    static func load() -> [FavoriteFolder] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let favorites = try? JSONDecoder().decode([FavoriteFolder].self, from: data) else { return [] }
        return favorites
    }

    private static func save(_ favorites: [FavoriteFolder]) {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func isFavorite(host: String, path: String) -> Bool {
        load().contains { $0.host == host && $0.path == path }
    }

    static func toggle(host: String, path: String, title: String, isFile: Bool = false) {
        var favorites = load()
        if let index = favorites.firstIndex(where: { $0.host == host && $0.path == path }) {
            favorites.remove(at: index)
        } else {
            favorites.append(FavoriteFolder(kind: .smb, host: host, path: path, title: title, isFile: isFile))
        }
        save(favorites)
        DispatchQueue.main.async { AppNavigator.shared.favoritesChanged() }
    }

    static func remove(_ id: String) {
        save(load().filter { $0.id != id })
    }
}
