import SwiftUI

/// A leading thumbnail for a video row — a real frame from the file (local or over `SmbHttpProxy`), cached via
/// `ThumbnailService`; falls back to a film icon while loading or if a frame couldn't be decoded.
struct VideoThumbnailView: View {
    let source: String
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: size * 16 / 9, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: source) {
            image = nil
            let remote: URL?
            if let (host, path) = SmbUri.parse(source) {
                remote = try? SmbHttpProxy.shared.url(host: host, path: path)
            } else {
                remote = nil
            }
            image = await ThumbnailService.shared.videoThumbnail(source: source, remoteURL: remote)
        }
    }
}

/// A leading icon box for a song row, sized to match `VideoThumbnailView`/folder icons so rows line up regardless
/// of media kind.
struct MusicThumbnailView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            Image(systemName: "music.note").foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A leading icon box for a folder row, sized the same way.
struct FolderThumbnailView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Toolbar control to pick the shared thumbnail size (small/medium/large) used across Video, Nhạc and Ảnh.
struct ThumbnailSizeMenu: View {
    @ObservedObject private var settings = LibrarySettings.shared

    var body: some View {
        Menu {
            Picker("Cỡ ảnh thu nhỏ", selection: $settings.thumbnailSize) {
                ForEach(ThumbnailSize.allCases) { size in Text(size.label).tag(size) }
            }
        } label: {
            Image(systemName: "square.grid.2x2")
        }
    }
}
