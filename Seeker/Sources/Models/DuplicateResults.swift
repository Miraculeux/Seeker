import Foundation

struct DuplicateResultDirectory: Identifiable {
    struct File: Identifiable {
        let url: URL
        let fileSize: Int64
        let suggestedKeep: URL
        let copies: [URL]
        let groupID: UUID
        let groupNumber: Int
        var id: URL { url }
        var isSuggestedKeep: Bool { url == suggestedKeep }
        var groupLabel: String { String(format: "Group %02d", groupNumber) }
    }

    let url: URL
    let files: [File]
    var id: URL { url }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }

    static func grouped(_ groups: [DuplicateFinder.Group], previousNumbers: [UUID: Int] = [:]) -> [Self] {
        var numbers = previousNumbers
        var nextNumber = (numbers.values.max() ?? 0) + 1
        // Number by a canonical member path, not size or hash-table order.
        // Existing numbers survive deletion for the rest of this scan.
        let orderedGroups = groups.compactMap { group -> (DuplicateFinder.Group, URL)? in
            guard let first = group.urls.min(by: nameOrdered) else { return nil }
            return (group, first)
        }.sorted { nameOrdered($0.1, $1.1) }
        var directories: [URL: [File]] = [:]
        for (group, _) in orderedGroups {
            guard let keep = group.urls.first else { continue }
            let number: Int
            if let existing = numbers[group.id] {
                number = existing
            } else {
                number = nextNumber
                numbers[group.id] = number
                nextNumber += 1
            }
            for url in group.urls {
                let parent = url.deletingLastPathComponent().standardizedFileURL
                directories[parent, default: []].append(File(
                    url: url, fileSize: group.fileSize, suggestedKeep: keep, copies: group.urls,
                    groupID: group.id, groupNumber: number
                ))
            }
        }
        return directories.map { directory, files in
            Self(url: directory, files: files.sorted { nameOrdered($0.url, $1.url) })
        }.sorted { nameOrdered($0.url, $1.url) }
    }

    private static func nameOrdered(_ lhs: URL, _ rhs: URL) -> Bool {
        let order = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
        if order != .orderedSame { return order == .orderedAscending }
        let pathOrder = lhs.path.localizedStandardCompare(rhs.path)
        if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
        return lhs.absoluteString < rhs.absoluteString
    }
}
