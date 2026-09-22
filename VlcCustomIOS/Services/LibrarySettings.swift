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

final class LibrarySettings: ObservableObject {
    static let shared = LibrarySettings()

    @Published var thumbnailSize: ThumbnailSize {
        didSet { UserDefaults.standard.set(thumbnailSize.rawValue, forKey: Self.key) }
    }

    private static let key = "library_thumbnail_size"

    private init() {
        thumbnailSize = ThumbnailSize(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .medium
    }
}
