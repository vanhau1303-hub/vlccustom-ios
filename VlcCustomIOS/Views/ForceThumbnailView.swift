import SwiftUI

/// "Buộc lấy thumbnail" (long-press options of a video): for files the automatic thumbnail could not handle. The user
/// picks the spot and the way the file is read, sees the frame libVLC gives — dark ones included, no time limit
/// worth mentioning — and decides whether it becomes the thumbnail.
struct ForceThumbnailView: View {
    let host: String
    let path: String
    let name: String

    private enum Route: String, CaseIterable, Identifiable {
        case auto, direct, proxy
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Tự động"
            case .direct: return "Thường"
            case .proxy: return "Tương thích"
            }
        }
    }

    @State private var percent: Double = 25
    @State private var route: Route = .auto
    @State private var working = false
    @State private var frame: UIImage?
    @State private var usedRoute: SmbPlaybackRoute?
    @State private var message: String?
    @State private var saved = false
    @State private var task: Task<Void, Never>?

    private var source: String { "smb://\(host)/\(path)" }

    var body: some View {
        Form {
            Section {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15))
                    if let frame {
                        Image(uiImage: frame).resizable().scaledToFit()
                    } else if working {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Đang lấy khung hình…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(name).lineLimit(2).truncationMode(.middle).textCase(nil)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Vị trí lấy khung hình")
                        Spacer()
                        Text("\(Int(percent))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $percent, in: 1...95, step: 1)
                    HStack {
                        ForEach([5, 10, 25, 50, 75], id: \.self) { value in
                            Button("\(value)%") { percent = Double(value) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                Picker("Cách đọc file", selection: $route) {
                    ForEach(Route.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Tự động: thử cách thường trước, không được thì chế độ tương thích. Khung tối vẫn được hiện ra để bạn tự quyết định.")
            }

            Section {
                Button {
                    grab()
                } label: {
                    Label(working ? "Đang lấy…" : "Lấy khung hình", systemImage: "camera.viewfinder")
                }
                .disabled(working)
                if working {
                    Button("Huỷ", role: .destructive) {
                        task?.cancel()
                        VLCSnapshotter.cancelAll()
                    }
                }
                if let frame, !working {
                    Button {
                        Task {
                            await ThumbnailService.shared.setThumbnail(frame, source: source)
                            if let usedRoute { SmbRoutePreferences.set(source, proxy: usedRoute == .proxy) }
                            ThumbnailEvents.shared.changed()
                            saved = true
                            message = "Đã dùng khung hình này làm thumbnail."
                        }
                    } label: {
                        Label(saved ? "Đã lưu làm thumbnail" : "Dùng làm thumbnail", systemImage: saved ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .disabled(saved)
                }
            }
        }
        .navigationTitle("Buộc lấy thumbnail")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
    }

    private func grab() {
        working = true
        saved = false
        frame = nil
        message = nil
        let position = Float(percent / 100)
        let routes: [SmbPlaybackRoute] = route == .auto ? [.direct, .proxy] : [route == .proxy ? .proxy : .direct]
        task = Task {
            let started = Date()
            let login = await SmbRegistry.shared.login(for: host)
            var image: CGImage?
            var used: SmbPlaybackRoute?
            for candidate in routes where image == nil && !Task.isCancelled {
                guard let target = SmbPlayback.location(host: host, path: path, route: candidate, login: login) else { continue }
                image = await VLCSnapshotter.frame(location: target.url, options: target.options, maxWidth: 640,
                                                   position: position, timeout: 60)
                if image != nil { used = candidate }
            }
            working = false
            guard !Task.isCancelled else {
                message = "Đã huỷ."
                return
            }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            if let image {
                frame = UIImage(cgImage: image)
                usedRoute = used
                let b = VLCSnapshotter.brightness(image)
                let dark = !VLCSnapshotter.isUsable(image)
                message = "Lấy được sau \(seconds)s qua cách \(used == .proxy ? "tương thích" : "thường")."
                    + (dark ? " Khung này khá tối (độ sáng \(Int(b.mean * 100))%) — có thể thử mốc khác." : "")
            } else {
                message = "Không lấy được khung hình sau \(seconds)s. Thử mốc khác hoặc đổi cách đọc file; nếu vẫn không được, dùng \"Kiểm tra file\" để xem định dạng."
            }
        }
    }
}
