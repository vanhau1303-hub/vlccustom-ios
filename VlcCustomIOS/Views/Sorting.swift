import SwiftUI

/// Common shape for anything that can be listed and sorted the same way (videos, songs, pictures).
protocol SortableMedia {
    var name: String { get }
    var sizeBytes: Int64 { get }
    var lastModified: Date { get }
}

extension VideoItem: SortableMedia {}
extension AudioItem: SortableMedia {}
extension ImageItem: SortableMedia {}
extension SmbEntry: SortableMedia {}

enum MediaSort: String, CaseIterable, Identifiable {
    case dateDesc = "Mới nhất"
    case dateAsc = "Cũ nhất"
    case nameAsc = "Tên A→Z"
    case nameDesc = "Tên Z→A"
    case sizeDesc = "Dung lượng lớn nhất"
    case sizeAsc = "Dung lượng nhỏ nhất"

    var id: String { rawValue }

    func apply<T: SortableMedia>(_ items: [T]) -> [T] {
        switch self {
        case .dateDesc: return items.sorted { $0.lastModified > $1.lastModified }
        case .dateAsc: return items.sorted { $0.lastModified < $1.lastModified }
        case .nameAsc: return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc: return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .sizeDesc: return items.sorted { $0.sizeBytes > $1.sizeBytes }
        case .sizeAsc: return items.sorted { $0.sizeBytes < $1.sizeBytes }
        }
    }
}

struct SortMenu: View {
    @Binding var sort: MediaSort

    var body: some View {
        Menu {
            Picker("Sắp xếp", selection: $sort) {
                ForEach(MediaSort.allCases) { option in Text(option.rawValue).tag(option) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }
}
