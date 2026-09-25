import SwiftUI
import UIKit

/// Bumped when thumbnails are dropped, so every thumbnail view reloads (their `.task(id:)` includes it).
final class ThumbnailEvents: ObservableObject {
    static let shared = ThumbnailEvents()
    @Published private(set) var version = 0
    private init() {}
    func changed() { version += 1 }
}

/// Long-press on an SMB file or folder: what it is, and everything that can be done with it.
struct SmbEntryOptionsSheet: View {
    let entry: SmbEntry
    let host: String
    let onOpen: () -> Void
    var onAddToPlaylist: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var navigator = AppNavigator.shared
    @State private var inspecting = false
    @State private var report: MediaInspector.Report?
    @State private var toast: String?

    private var source: String { "smb://\(host)/\(entry.path)" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        SmbEntryThumbnail(entry: entry, host: host, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name).font(.headline).lineLimit(3)
                            Text(kindLabel).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if entry.kind != .other {
                        action(entry.isDirectory ? "Mở thư mục" : "Mở", icon: entry.kind == .video || entry.kind == .audio ? "play.fill" : "arrow.up.forward.square") {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpen() }
                        }
                    }
                    let starred = FavoritesStore.isFavorite(host: host, path: entry.path)
                    action(starred ? "Bỏ khỏi Yêu thích" : "Thêm vào Yêu thích", icon: starred ? "star.slash" : "star") {
                        FavoritesStore.toggle(host: host, path: entry.path, title: entry.name, isFile: !entry.isDirectory)
                        show(starred ? "Đã bỏ khỏi Yêu thích" : "Đã thêm vào Yêu thích")
                    }
                    if entry.kind == .video || entry.kind == .audio {
                        let proxy = SmbRoutePreferences.prefersProxy(source)
                        action(proxy ? "Phát bằng chế độ thường" : "Phát bằng chế độ tương thích",
                               icon: "arrow.triangle.2.circlepath") {
                            SmbRoutePreferences.set(source, proxy: !proxy)
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpen() }
                        }
                    }
                    if entry.kind == .video, let onAddToPlaylist {
                        action("Thêm vào playlist", icon: "text.badge.plus") {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onAddToPlaylist() }
                        }
                    }
                }

                if entry.kind == .video || entry.kind == .audio {
                    Section {
                        action(inspecting ? "Đang kiểm tra…" : "Kiểm tra file (codec, độ phân giải…)", icon: "stethoscope") {
                            guard !inspecting else { return }
                            inspecting = true
                            report = nil
                            Task {
                                report = await MediaInspector.inspect(host: host, path: entry.path)
                                inspecting = false
                            }
                        }
                        .disabled(inspecting)
                        if let report {
                            ForEach(report.lines, id: \.self) { line in
                                Text(line).font(.footnote)
                            }
                        }
                    } footer: {
                        Text("Dùng khi một file không phát được: cho biết định dạng hình/tiếng bên trong, hoặc file bị hỏng/không đọc được.")
                    }
                }

                Section("Thông tin") {
                    if !entry.isDirectory {
                        info("Dung lượng", ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                    }
                    if entry.lastModified != .distantPast {
                        info("Sửa lần cuối", entry.lastModified.formatted(date: .abbreviated, time: .shortened))
                    }
                    info("Máy chủ", host)
                    info("Đường dẫn", entry.path)
                }

                Section {
                    action("Sao chép tên", icon: "doc.on.doc") {
                        UIPasteboard.general.string = entry.name
                        show("Đã sao chép tên")
                    }
                    action("Sao chép đường dẫn smb://", icon: "link") {
                        UIPasteboard.general.string = source
                        show("Đã sao chép đường dẫn")
                    }
                    if entry.kind == .video || entry.kind == .image || entry.kind == .audio {
                        action("Tạo lại thumbnail", icon: "arrow.clockwise") {
                            Task {
                                await ThumbnailService.shared.forget(source: source)
                                ThumbnailEvents.shared.changed()
                                show("Thumbnail sẽ được tạo lại")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tuỳ chọn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var kindLabel: String {
        switch entry.kind {
        case .folder: return "Thư mục"
        case .video: return "Video · \((entry.name as NSString).pathExtension.uppercased())"
        case .image: return "Ảnh · \((entry.name as NSString).pathExtension.uppercased())"
        case .audio: return "Nhạc · \((entry.name as NSString).pathExtension.uppercased())"
        case .other: return "File · \((entry.name as NSString).pathExtension.uppercased())"
        }
    }

    private func action(_ title: String, icon: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: icon) }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { if toast == message { toast = nil } } }
    }
}
