import SwiftUI

/// A leading thumbnail for a video row — a real frame from the file (local via AVFoundation, SMB via libVLC's own thumbnailer), cached via
/// `ThumbnailService`; falls back to a film icon while loading or if a frame couldn't be decoded. Skips fetching
/// entirely while a video is playing elsewhere in the app (`PlaybackActivity`), so a still-mounted list underneath
/// the player doesn't compete with it for the same SMB connection/bandwidth.
struct VideoThumbnailView: View {
    let source: String
    let size: CGFloat
    @State private var image: UIImage?
    @ObservedObject private var activity = PlaybackActivity.shared

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
            image = await ThumbnailService.shared.cachedThumbnail(source: source)
            // While a video is streaming, only show thumbnails that already exist — generating one is another SMB
            // session + decoder competing with playback.
            guard image == nil, !activity.isBusy else { return }
            if let (host, path) = SmbUri.parse(source) {
                image = await ThumbnailService.shared.smbVideoThumbnail(source: source, host: host, path: path)
            } else {
                image = await ThumbnailService.shared.videoThumbnail(source: source, remoteURL: nil)
            }
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
    /// Height of the box (and its width too unless `width` is given).
    let size: CGFloat
    var width: CGFloat?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.55))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: width ?? size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Toolbar control to pick the shared view mode (list/grid) and thumbnail size (small/medium/large), used
/// consistently across Video, Nhạc, Ảnh and Yêu thích.
struct ThumbnailSizeMenu: View {
    @ObservedObject private var settings = LibrarySettings.shared

    var body: some View {
        Menu {
            Picker("Chế độ xem", selection: $settings.viewMode) {
                ForEach(LibraryViewMode.allCases) { mode in Label(mode.label, systemImage: mode.icon).tag(mode) }
            }
            Picker("Cỡ ảnh thu nhỏ", selection: $settings.thumbnailSize) {
                ForEach(ThumbnailSize.allCases) { size in Text(size.label).tag(size) }
            }
        } label: {
            Image(systemName: settings.viewMode.icon)
        }
    }
}

/// A grid cell for a video: thumbnail on top, name below.
struct VideoGridCell: View {
    let source: String
    let name: String
    let cellWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VideoThumbnailView(source: source, size: cellWidth * 9 / 16)
            Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(width: cellWidth, alignment: .leading)
    }
}

/// A grid cell for a song.
struct MusicGridCell: View {
    let name: String
    let cellWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MusicThumbnailView(size: cellWidth)
            Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(width: cellWidth, alignment: .leading)
    }
}

/// A grid cell for a folder.
struct FolderGridCell: View {
    let name: String
    let cellWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FolderThumbnailView(size: cellWidth)
            Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(width: cellWidth, alignment: .leading)
    }
}

/// A song's cover art (see `ThumbnailService.audioCover`), or a music-note box when it has none.
struct AudioCoverView: View {
    let source: String
    let size: CGFloat
    var width: CGFloat?
    @State private var cover: UIImage?
    @ObservedObject private var activity = PlaybackActivity.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
            }
        }
        .frame(width: width ?? size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: source) {
            cover = await ThumbnailService.shared.cachedThumbnail(source: source)
            guard cover == nil, !activity.isBusy else { return }
            cover = await ThumbnailService.shared.audioCover(source: source)
        }
    }
}
