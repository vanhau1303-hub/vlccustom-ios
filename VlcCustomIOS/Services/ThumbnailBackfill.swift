import Foundation
import SwiftUI
import UIKit

/// Makes the missing thumbnails — and the moving-thumbnail frames, whether or not they are shown — of the SMB folders
/// already opened, in the background, one at a time. Rules:
/// - the folder being browsed always goes first (it interrupts whatever folder was being done);
/// - then the remembered folders in the user's order (Cài đặt → Thumbnail nền → Thư mục đã xem: drag to reorder,
///   tick / untick to include);
/// - playback first: while a video is open it waits, and it only starts a job when no thumbnail for the screen is
///   being made.
@MainActor
final class ThumbnailBackfill: ObservableObject {
    static let shared = ThumbnailBackfill()
    static let enabledKey = "thumbs_backfill"
    private static let visitedKey = "thumbs_backfill_folders"
    private static let excludedKey = "thumbs_backfill_excluded"
    private static let maxFolders = 150

    struct Folder: Codable, Hashable {
        let host: String
        let path: String
        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    }

    enum Phase: Equatable {
        case idle, scanning, working, waitingForVideo, waitingForApp, paused
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { PlaybackDiagnostics.append("backfill: \(phase) · \(folderName)") } }
    }
    @Published private(set) var folderName = ""
    /// The folder being worked on: what is on disk right now, re-counted after every job.
    @Published private(set) var current: Folder?
    /// Folders still queued after the current one.
    @Published private(set) var foldersLeft = 0
    @Published var userPaused = false
    @Published private(set) var visitedCount = 0
    /// Remembered folders, in the order the background pass goes through them (the user's order).
    @Published private(set) var visited: [Folder]
    /// Folders the user unticked: not done in the background (still done while being browsed).
    @Published private(set) var excluded: Set<Folder>
    /// What happened to each folder in this session.
    @Published private(set) var states: [Folder: FolderState] = [:]
    /// Thumbnails actually on disk for each folder looked at in this session.
    @Published private(set) var stats: [Folder: ThumbnailService.FolderStats] = [:]
    /// The folder on screen right now.
    @Published private(set) var browsing: Folder?

    enum FolderState: Equatable {
        case waiting, scanning, working, complete, unreachable
    }

    private var queue: [Folder] = []
    private var finished: Set<Folder> = []
    private var task: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        visited = defaults.data(forKey: Self.visitedKey).flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? []
        excluded = Set(defaults.data(forKey: Self.excludedKey).flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? [])
        visitedCount = visited.count
    }

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// A folder was opened (Mạng / Yêu thích): remembered (a new one goes to the end of the user's order) and done
    /// right away, before any other folder.
    func visit(host: String, path: String) {
        let folder = Folder(host: host, path: path)
        if !visited.contains(folder) {
            visited.append(folder)
            if visited.count > Self.maxFolders { visited.removeFirst(visited.count - Self.maxFolders) }
            save()
        }
        browsing = folder
        if !finished.contains(folder) { states[folder] = .waiting }
        start()
    }

    /// App start: go through every remembered, ticked folder.
    func startAll() {
        queue = visited.filter { !finished.contains($0) && !excluded.contains($0) }
        for folder in queue { states[folder] = .waiting }
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

    func move(from source: IndexSet, to destination: Int) {
        visited.move(fromOffsets: source, toOffset: destination)
        save()
        // The queue follows the new order.
        let pending = Set(queue)
        queue = visited.filter { pending.contains($0) }
    }

    func setIncluded(_ folder: Folder, _ included: Bool) {
        if included {
            excluded.remove(folder)
            if !finished.contains(folder), !queue.contains(folder) {
                // Keep the user's order.
                queue.append(folder)
                queue = visited.filter { queue.contains($0) }
                states[folder] = .waiting
            }
            start()
        } else {
            excluded.insert(folder)
            queue.removeAll { $0 == folder }
            if states[folder] == .waiting { states[folder] = nil }
        }
        save()
    }

    func forget(_ folder: Folder) {
        visited.removeAll { $0 == folder }
        excluded.remove(folder)
        queue.removeAll { $0 == folder }
        states[folder] = nil
        save()
    }

    func forgetFolders() {
        states = [:]
        visited = []
        excluded = []
        save()
        stop()
    }

    private func save() {
        visitedCount = visited.count
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(visited) { defaults.set(data, forKey: Self.visitedKey) }
        if let data = try? JSONEncoder().encode(Array(excluded)) { defaults.set(data, forKey: Self.excludedKey) }
    }

    private func stop() {
        task?.cancel()
        task = nil
        queue = []
        phase = .idle
    }

    private func start() {
        guard enabled, task == nil, nextFolderAvailable else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    private var nextFolderAvailable: Bool {
        (browsing.map { !finished.contains($0) } ?? false) || !queue.isEmpty
    }

    /// The folder on screen first, then the queue in the user's order.
    private func nextFolder() -> Folder? {
        if let browsing, !finished.contains(browsing) {
            queue.removeAll { $0 == browsing }
            return browsing
        }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    private func run() async {
        while !Task.isCancelled, let folder = nextFolder() {
            foldersLeft = queue.count
            let completed = await process(folder)
            if Task.isCancelled { break }
            if completed {
                finished.insert(folder)
            } else if !queue.contains(folder) {
                // Interrupted by a newly browsed folder: carry on with this one after it.
                queue.insert(folder, at: 0)
                states[folder] = .waiting
            }
        }
        phase = .idle
        current = nil
        task = nil
        ThumbnailEvents.shared.changed()
        if nextFolderAvailable, !Task.isCancelled { start() }
    }

    /// Returns false when it stopped half-way because another folder is now being browsed.
    private func process(_ folder: Folder) async -> Bool {
        phase = .scanning
        states[folder] = .scanning
        folderName = folder.name
        current = folder
        guard let connection = await SmbRegistry.shared.getOrReconnect(folder.host),
              let items = try? await connection.list(path: folder.path) else {
            states[folder] = .unreachable
            PlaybackDiagnostics.append("backfill: cannot list \(folder.host)/\(folder.path)")
            return true
        }
        let service = ThumbnailService.shared
        let entries = items.filter { $0.kind != .other }
        stats[folder] = await service.stats(host: folder.host, entries: entries)

        // Normal thumbnails first, then the moving-thumbnail frames (made even while that display is off, so they
        // are there the moment it is switched on).
        var jobs: [(entry: SmbEntry, preview: Bool)] = []
        for entry in entries {
            let source = entry.isDirectory ? "smbfolder://\(folder.host)/\(entry.path)" : "smb://\(folder.host)/\(entry.path)"
            if await service.needsThumbnail(source: source) { jobs.append((entry, false)) }
        }
        for entry in entries where entry.kind == .video {
            if await service.needsPreview(source: "smb://\(folder.host)/\(entry.path)") { jobs.append((entry, true)) }
        }
        PlaybackDiagnostics.append("backfill: \(folder.path) — \(entries.count) items, \(jobs.count) to make")
        guard !jobs.isEmpty else {
            states[folder] = .complete
            return true
        }
        states[folder] = .working

        var sinceRefresh = 0
        for job in jobs {
            if Task.isCancelled { return false }
            if let browsing, browsing != folder, !finished.contains(browsing) { return false }
            let source = job.entry.isDirectory ? "smbfolder://\(folder.host)/\(job.entry.path)" : "smb://\(folder.host)/\(job.entry.path)"
            // Made meanwhile by the screen (the folder on screen makes its own): nothing to do.
            if job.preview ? !(await service.needsPreview(source: source)) : !(await service.needsThumbnail(source: source)) {
                continue
            }
            // A video opened (or the app left the screen) half-way makes the job give up without a result: wait
            // and do it again.
            var attempts = 0
            repeat {
                await waitForTurn()
                if Task.isCancelled { return false }
                phase = .working
                await make(job.entry, preview: job.preview, host: folder.host, source: source)
                attempts += 1
            } while (PlaybackActivity.shared.isBusy || !Self.appActive) && attempts < 5
            stats[folder] = await service.stats(host: folder.host, entries: entries)
            sinceRefresh += 1
            if sinceRefresh >= 4 {
                sinceRefresh = 0
                ThumbnailEvents.shared.changed()
            }
        }
        stats[folder] = await service.stats(host: folder.host, entries: entries)
        states[folder] = .complete
        PlaybackDiagnostics.append("backfill: \(folder.path) done")
        return true
    }

    private static var appActive: Bool { UIApplication.shared.applicationState == .active }

    private func make(_ entry: SmbEntry, preview: Bool, host: String, source: String) async {
        let service = ThumbnailService.shared
        if preview {
            _ = await service.smbPreview(source: source, host: host, path: entry.path, screen: false)
            return
        }
        switch entry.kind {
        case .video: _ = await service.smbVideoThumbnail(source: source, host: host, path: entry.path, screen: false)
        case .image: _ = await service.smbImageThumbnail(source: source, host: host, path: entry.path, screen: false)
        case .audio: _ = await service.audioCover(source: source, screen: false)
        case .folder: _ = await service.folderThumbnail(host: host, path: entry.path, screen: false)
        case .other: break
        }
    }

    /// Holds the job while the user paused it, a video is open or the app is not on screen (iOS stops hardware
    /// decoding in the background, so frames would fail). Thumbnails for the folder on screen do not need waiting
    /// for: they jump ahead in `ThumbnailService`'s queue on their own.
    private func waitForTurn() async {
        while !Task.isCancelled {
            if userPaused {
                phase = .paused
            } else if PlaybackActivity.shared.isBusy {
                phase = .waitingForVideo
            } else if !Self.appActive {
                phase = .waitingForApp
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
                Text(title).font(.subheadline).lineLimit(2).truncationMode(.middle)
                if backfill.phase != .idle, let folder = backfill.current, let stats = backfill.stats[folder] {
                    ThumbnailStatsView(stats: stats, showBars: true)
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
        case .scanning: return "Đang đọc thư mục \(backfill.folderName)…"
        case .paused: return "Đã tạm dừng · \(backfill.folderName)"
        case .waitingForVideo: return "Chờ xem xong video · \(backfill.folderName)"
        case .waitingForApp: return "Chờ mở lại app · \(backfill.folderName)"
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

/// "Thumbnail 25/30 · Động 10/22 · 2 lỗi", counted from what is on disk.
struct ThumbnailStatsView: View {
    let stats: ThumbnailService.FolderStats
    var showBars = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Thumbnail \(stats.thumbs)/\(stats.media)")
                if stats.videos > 0 { Text("Động \(stats.previews)/\(stats.videos)") }
                if stats.failed > 0 { Text("\(stats.failed) lỗi").foregroundStyle(.orange) }
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if showBars {
                ProgressView(value: Double(stats.thumbs + stats.failed), total: Double(max(1, stats.media)))
                if stats.videos > 0 {
                    ProgressView(value: Double(stats.previews + stats.previewsFailed), total: Double(stats.videos))
                        .tint(.purple)
                }
            }
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
                ForEach(Array(backfill.visited.enumerated()), id: \.element) { index, folder in
                    let included = !backfill.excluded.contains(folder)
                    HStack(spacing: 10) {
                        Button {
                            backfill.setIncluded(folder, !included)
                        } label: {
                            Image(systemName: included ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(included ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                                Text(folder.name).lineLimit(1).truncationMode(.middle)
                                if backfill.browsing == folder {
                                    Text("đang xem").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                                }
                            }
                            Text("\(folder.host)/\(folder.path)").font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        .opacity(included ? 1 : 0.5)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            stateView(backfill.states[folder])
                            if let stats = backfill.stats[folder] {
                                Text("\(stats.thumbs)/\(stats.media)" + (stats.videos > 0 ? " · động \(stats.previews)/\(stats.videos)" : ""))
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Quên", role: .destructive) { backfill.forget(folder) }
                    }
                }
                .onMove { backfill.move(from: $0, to: $1) }
            } header: {
                Text("Thư mục đã xem (\(backfill.visited.count))")
            } footer: {
                Text("Thư mục đang xem luôn được làm trước. Sau đó theo thứ tự trong danh sách: bấm \"Sửa\" rồi kéo ≡ để đổi thứ tự, bấm vòng tròn để chọn / bỏ chọn thư mục, vuốt sang trái để quên. Lấy cả thumbnail thường lẫn thumbnail động.")
            }
            Section {
                Button("Kiểm tra lại tất cả ngay") { backfill.restartAll() }
                Button("Quên toàn bộ danh sách", role: .destructive) { backfill.forgetFolders() }
            }
        }
        .navigationTitle("Thumbnail nền")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    @ViewBuilder
    private func stateView(_ state: ThumbnailBackfill.FolderState?) -> some View {
        switch state {
        case .waiting?:
            Text("Đang chờ").font(.caption).foregroundStyle(.secondary)
        case .scanning?, .working?:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Đang làm").font(.caption)
            }
        case .complete?:
            Label("Xong", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
        case .unreachable?:
            Label("Không mở được", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case nil:
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Buộc lấy thumbnail": runs in the background (the options sheet closes at once) — the agreed spots past black
/// frames, longer limits, normal then compatibility route, saved with its moving frames. Waits while a video is open
/// and goes again if one opened half-way. The cell shows a spinner meanwhile, and a warning badge if it failed.
@MainActor
final class ForcedThumbnails: ObservableObject {
    static let shared = ForcedThumbnails()
    @Published private(set) var running: Set<String> = []
    @Published private(set) var failed: Set<String> = []
    private var queue: [(source: String, host: String, path: String)] = []
    private var worker: Task<Void, Never>?

    func force(host: String, path: String) {
        let source = "smb://\(host)/\(path)"
        guard !running.contains(source) else { return }
        running.insert(source)
        failed.remove(source)
        queue.append((source, host, path))
        if worker == nil {
            worker = Task { [weak self] in await self?.work() }
        }
    }

    private func work() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            var image: UIImage?
            for _ in 0..<5 {
                while PlaybackActivity.shared.isBusy { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                image = await ThumbnailService.shared.forceVideoThumbnail(source: job.source, host: job.host, path: job.path) { _ in }
                // Given up only because a video was opened meanwhile: try again once it is closed.
                if image != nil || !PlaybackActivity.shared.isBusy { break }
            }
            running.remove(job.source)
            if image == nil {
                failed.insert(job.source)
                PlaybackDiagnostics.append("thumb: forced \(job.path) — no frame on either route")
            }
            ThumbnailEvents.shared.changed()
        }
        worker = nil
    }
}
