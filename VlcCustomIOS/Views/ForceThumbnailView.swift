import SwiftUI

/// "Buộc lấy thumbnail" (long-press options of a video): for files the automatic thumbnail could not handle. Starts
/// by itself: the agreed spots (25%, then 40/60/15/75% past black frames) with much more time, the normal way first
/// and the compatibility way next; the result is saved straight away, moving-thumbnail frames included.
struct ForceThumbnailView: View {
    let host: String
    let path: String
    let name: String

    @State private var working = false
    @State private var frame: UIImage?
    @State private var message: String?
    @State private var failed = false
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
                        ProgressView()
                    } else {
                        Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                            .font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                if let message {
                    HStack(spacing: 8) {
                        if working { ProgressView().controlSize(.small) }
                        Text(message).font(.footnote).foregroundStyle(failed ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(name).lineLimit(2).truncationMode(.middle).textCase(nil)
            } footer: {
                Text("Tự thử các mốc 25%, 40%, 60%, 15%, 75% (bỏ qua khung đen), cách đọc thường rồi chế độ tương thích, chờ lâu hơn bình thường. Lấy được là lưu luôn, kèm thumbnail động.")
            }

            Section {
                if working {
                    Button("Huỷ", role: .destructive) {
                        task?.cancel()
                        VLCSnapshotter.cancelAll()
                    }
                } else {
                    Button { run() } label: { Label("Thử lại", systemImage: "arrow.clockwise") }
                }
            }
        }
        .navigationTitle("Buộc lấy thumbnail")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if task == nil { run() } }
        .onDisappear { task?.cancel() }
    }

    private func run() {
        working = true
        failed = false
        frame = nil
        message = "Đang lấy…"
        task = Task {
            let started = Date()
            let image = await ThumbnailService.shared.forceVideoThumbnail(source: source, host: host, path: path) { step in
                message = step
            }
            working = false
            let seconds = String(format: "%.0f", Date().timeIntervalSince(started))
            if Task.isCancelled {
                message = "Đã huỷ."
            } else if let image {
                frame = image
                message = "Đã lưu làm thumbnail (\(seconds)s)."
                ThumbnailEvents.shared.changed()
            } else {
                failed = true
                message = "Không lấy được khung hình nào sau \(seconds)s, cả hai cách đọc. Dùng \"Kiểm tra file\" để xem định dạng bên trong."
            }
        }
    }
}
