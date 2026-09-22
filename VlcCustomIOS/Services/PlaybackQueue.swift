import Foundation
import Combine

/// The list of videos currently being played through (a folder, a search result...) and where in it we are.
final class PlaybackQueue: ObservableObject {
    static let shared = PlaybackQueue()

    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var index: Int = 0
    private(set) var label: String = ""

    var current: VideoItem? { items.indices.contains(index) ? items[index] : nil }
    var hasNext: Bool { index < items.count - 1 }
    var hasPrevious: Bool { index > 0 }

    func start(_ items: [VideoItem], index: Int, label: String = "") {
        self.items = items
        self.index = index
        self.label = label
    }

    @discardableResult
    func moveNext() -> VideoItem? {
        guard hasNext else { return nil }
        index += 1
        return current
    }

    @discardableResult
    func movePrevious() -> VideoItem? {
        guard hasPrevious else { return nil }
        index -= 1
        return current
    }
}
