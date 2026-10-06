import Foundation
import SwiftUI

/// Makes the missing thumbnails of every SMB folder already opened, in the background, one at a time — so going
/// back to a folder shows its pictures at once. Playback comes first: while a video is open it waits, and it only
/// starts a job when no thumbnail for the folder on screen is being made (those always go first).
/// Cài đặt → "Thumbnail nền" (on by default): progress and every remembered folder with its state.
@MainActor
final class ThumbnailBackfill: ObservableObject {
    static let shared = ThumbnailBackfill()
    static let enabledKey = "thumbs_backfill"
    private static let visitedKey = "thumbs_backfill_folders"
    private static let maxFolders = 150

    struct Folder: Codable, Hashable {
        let host: String
        let path: String
    }

    enum Phase: Equatable {
        case idle, scanning, working, waitingForVideo, waitingForScreen, paused
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var folderName = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    /// Folders still queued after the current one.
    @Published private(set) var foldersLeft = 0
    @Published var userPaused = false
    @Published private(set) var visitedCount = 0
    /// Remembered folders, most recently opened first.
    @Published private(set) var visited: [Folder]
    /// What happened to each folder in this session.
    @Published private(set) var states: [Folder: FolderState] = [:]

    enum FolderState: Equatable {
        case waiting, scanning
        case working(done: Int, total: Int)
        case complete(made: Int)
        case unreachable
    }

    private var queue: [Folder] = []
    private var finished: Set<Folder> = []
    private var task: Task<Void, Never>?

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.visitedKey)
        visited = data.flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? []
        visitedCount = visited.count
    }

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// A folder was opened (Mạng / Yêu thích): remember it and, if not done yet in this session, queue it first.
    func visit(host: String, path: String) {
        let folder = Folder(host: host, path: path)
        visited.removeAll { $0 == folder }
        visited.insert(folder, at: 0)
        if visited.count > Self.maxFolders { visited.removeLast(visited.count - Self.maxFolders) }
        visitedCount = visited.count
        if let data = try? JSONEncoder().encode(visited) { UserDefaults.standard.set(data, forKey: Self.visitedKey) }
        // The folder on screen is handled by its own view right now; here it only needs a pass later (sub-folders'
        // mosaics, and whatever the view did not get to before the user left).
        if !finished.contains(folder), !queue.contains(folder) {
            queue.append(folder)
            states[folder] = .waiting
        }
        start()
    }

    /// App start: go through every remembered folder.
    func startAll() {
        for folder in visited where !finished.contains(folder) && !queue.contains(folder) {
            queue.append(folder)
            states[folder] = .waiting
        }
        start()
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { startAll() } else { stop() }
    }

    /// Runs every remembered folder again now (e.g. after deleting thumbnails).
    func restartAll() {
        finished = []
        startAll()
    }

    func forget(_ folder: Folder) {
        visited.removeAll { $0 == folder }
        queue.removeAll { $0 == folder }
        states[folder] = nil
        visitedCount = visited.count
        if let data = try? JSONEncoder().encode(visited) { UserDefaults.standard.set(data, forKey: Self.visitedKey) }
    }

    func forgetFolders() {
        states = [:]
        visited = []
        visitedCount = 0
        UserDefaults.standard.removeObject(forKey: Self.visitedKey)
        stop()
    }

    private func stop() {
        task?.cancel()
        task = nil
        queue = []
        phase = .idle
    }

    private func start() {
        guard enabled, task == nil, !queue.isEmpty else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while !Task.isCancelled, !queue.isEmpty {
            let folder = queue.removeFirst()
            foldersLeft = queue.count
            await process(folder)
            if !Task.isCancelled { finished.insert(folder) }
        }
        phase = .idle
        total = 0
        done = 0
        task = nil
        ThumbnailEvents.shared.changed()
    }

    private func process(_ folder: Folder) async {
        phase = .scanning
        states[folder] = .scanning
        folderName = folder.path.split(separator: "/").last.map(String.init) ?? folder.path
        guard let connection = await SmbRegistry.shared.getOrReconnect(folder.host),
              let items = try? await connection.list(path: folder.path) else {
            states[folder] = .unreachable
            return
        }
        let service = ThumbnailService.shared
        let animated = UserDefaults.standard.bool(forKey: ThumbnailPolicy.animatedKey)

        var jobs: [(entry: SmbEntry, preview: Bool)] = []
        for entry in items where entry.kind != .other {
            let source = entry.isDirectory ? "smbfolder://\(folder.host)/\(entry.path)" : "smb://\(folder.host)/\(entry.path)"
            if await service.needsThumbnail(source: source) { jobs.append((entry, false)) }
        }
        if animated {
            for entry in items where entry.kind == .video {
                if await service.needsPreview(source: "smb://\(folder.host)/\(entry.path)") { jobs.append((entry, true)) }
            }
        }
        guard !jobs.isEmpty else {
            states[folder] = .complete(made: 0)
            return
        }
        total = jobs.count
        done = 0
        states[folder] = .working(done: 0, total: jobs.count)

        for job in jobs {
            if Task.isCancelled { return }
            let source = job.entry.isDirectory ? "smbfolder://\(folder.host)/\(job.entry.path)" : "smb://\(folder.host)/\(job.entry.path)"
            // A video opened half-way makes the job give up without a result: wait and do it again.
            var attempts = 0
            repeat {
                await waitForTurn()
                if Task.isCancelled { return }
                phase = .working
                await make(job.entry, preview: job.preview, host: folder.host, source: source)
                attempts += 1
            } while PlaybackActivity.shared.isBusy && attempts < 5
            done += 1
            states[folder] = .working(done: done, total: total)
            if done % 4 == 0 { ThumbnailEvents.shared.changed() }
        }
        states[folder] = .complete(made: total)
    }

    private func make(_ entry: SmbEntry, preview: Bool, host: String, source: String) async {
        let service = ThumbnailService.shared
        if preview {
            _ = await service.smbPreview(source: source, host: host, path: entry.path)
            return
        }
        switch entry.kind {
        case .video: _ = await service.smbVideoThumbnail(source: source, host: host, path: entry.path)
        case .image: _ = await service.smbImageThumbnail(source: source, host: host, path: entry.path)
        case .audio: _ = await service.audioCover(source: source)
        case .folder: _ = await service.folderThumbnail(host: host, path: entry.path)
        case .other: break
        }
    }

    /// Holds the job while the user paused it, a video is open, or thumbnails for the screen are being made.
    private func waitForTurn() async {
        while !Task.isCancelled {
            if userPaused {
                phase = .paused
            } else if PlaybackActivity.shared.isBusy {
                phase = .waitingForVideo
            } else if !(await ThumbnailService.shared.isIdle) {
                phase = .waitingForScreen
            } else {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

/// Current state of the background pass, for Cài đặt.
struct ThumbnailBackfillStatusRow: View {
    @ObservedObject private var backfill = ThumbnailBackfill.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title).lineLimit(2).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if backfill.phase != .idle, backfill.total > 0 {
                        Text("\(backfill.done)/\(backfill.total)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                if backfill.phase != .idle, backfill.total > 0 {
                    ProgressView(value: Double(backfill.done), total: Double(max(1, backfill.total)))
                }
            }
            if backfill.phase != .idle {
                Button {
                    backfill.userPaused.toggle()
                } label: {
                    Image(systemName: backfill.userPaused ? "play.fill" : "pause.fill").frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        let more = backfill.foldersLeft > 0 ? " (+\(backfill.foldersLeft) thư mục chờ)" : ""
        switch backfill.phase {
        case .idle: return "Không có gì cần làm — thumbnail các thư mục đã xem đã đủ"
        case .scanning: return "Đang xem thư mục \(backfill.folderName)…"
        case .paused: return "Đã tạm dừng · \(backfill.folderName)"
        case .waitingForVideo: return "Chờ xem xong video · \(backfill.folderName)"
        case .waitingForScreen: return "Nhường thư mục đang mở · \(backfill.folderName)"
        case .working: return "Đang tạo · \(backfill.folderName)\(more)"
        }
    }

    private var icon: String {
        switch backfill.phase {
        case .idle: return "checkmark.circle"
        case .paused: return "pause.circle"
        case .waitingForVideo: return "play.rectangle"
        default: return "photo.stack"
        }
    }
}

/// Every remembered folder and what the background pass did with it.
struct ThumbnailBackfillFoldersView: View {
    @ObservedObject private var backfill = ThumbnailBackfill.shared

    var body: some View {
        List {
            Section { ThumbnailBackfillStatusRow() }
            Section {
                ForEach(backfill.visited, id: \.self) { folder in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.path.split(separator: "/").last.map(String.init) ?? folder.path)
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(folder.host)/\(folder.path)").font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 8)
                        stateView(backfill.states[folder])
                    }
                    .swipeActions {
                        Button("Quên", role: .destructive) { backfill.forget(folder) }
                    }
                }
            } header: {
                Text("Thư mục đã xem (\(backfill.visited.count))")
            } footer: {
                Text("Vuốt sang trái để bỏ một thư mục khỏi danh sách.")
            }
            Section {
                Button("Kiểm tra lại tất cả ngay") { backfill.restartAll() }
                Button("Quên toàn bộ danh sách", role: .destructive) { backfill.forgetFolders() }
            }
        }
        .navigationTitle("Thumbnail nền")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func stateView(_ state: ThumbnailBackfill.FolderState?) -> some View {
        switch state {
        case .waiting?:
            Text("Đang chờ").font(.caption).foregroundStyle(.secondary)
        case .scanning?:
            ProgressView().controlSize(.small)
        case .working(let done, let total)?:
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(done)/\(total)").font(.caption).monospacedDigit()
                ProgressView(value: Double(done), total: Double(max(1, total))).frame(width: 60)
            }
        case .complete(let made)?:
            Label(made > 0 ? "Xong (+\(made))" : "Đủ", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
        case .unreachable?:
            Label("Không mở được", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case nil:
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }
}
