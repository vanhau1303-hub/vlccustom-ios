import Foundation
import CoreGraphics

/// A persisted, user-adjustable thumbnail size shared across the Video, Nhạc and Ảnh tabs — the iOS equivalent of
/// the Android app's thumbnail-size setting.
enum ThumbnailSize: String, CaseIterable, Identifiable, Codable {
    case small, medium, large

    var id: String { rawValue }

    /// Height of a list-row thumbnail (video rows use a 16:9 width from this).
    var rowHeight: CGFloat {
        switch self {
        case .small: return 44
        case .medium: return 64
        case .large: return 92
        }
    }

    /// Side length of a grid cell (Ảnh tab).
    var gridCell: CGFloat {
        switch self {
        case .small: return 84
        case .medium: return 112
        case .large: return 150
        }
    }

    var label: String {
        switch self {
        case .small: return "Nhỏ"
        case .medium: return "Vừa"
        case .large: return "Lớn"
        }
    }
}

/// How a folder's contents are laid out — a thumbnail grid, or a single-column list (which already carries the same
/// thumbnail plus name/size, i.e. what a "detail" view would add).
enum LibraryViewMode: String, CaseIterable, Identifiable, Codable {
    case list, grid

    var id: String { rawValue }
    var label: String { self == .list ? "Danh sách" : "Lưới" }
    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

final class LibrarySettings: ObservableObject {
    static let shared = LibrarySettings()

    @Published var thumbnailSize: ThumbnailSize {
        didSet { UserDefaults.standard.set(thumbnailSize.rawValue, forKey: Self.sizeKey) }
    }
    @Published var viewMode: LibraryViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: Self.modeKey) }
    }

    private static let sizeKey = "library_thumbnail_size"
    private static let modeKey = "library_view_mode"

    private init() {
        thumbnailSize = ThumbnailSize(rawValue: UserDefaults.standard.string(forKey: Self.sizeKey) ?? "") ?? .medium
        viewMode = LibraryViewMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .list
    }
}
