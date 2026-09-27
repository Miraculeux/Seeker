import Foundation

struct DuplicateResultDirectory: Identifiable {
    struct File: Identifiable {
        let url: URL
        let fileSize: Int64
        let suggestedKeep: URL
        let copies: [URL]
        var id: URL { url }
        var isSuggestedKeep: Bool { url == suggestedKeep }
    }

    let url: URL
    let files: [File]
    var id: URL { url }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }

    static func grouped(_ groups: [DuplicateFinder.Group]) -> [Self] {
        var directories: [URL: [File]] = [:]
        for group in groups {
            guard let keep = group.urls.first else { continue }
            for url in group.urls {
                let parent = url.deletingLastPathComponent().standardizedFileURL
                directories[parent, default: []].append(File(
                    url: url, fileSize: group.fileSize, suggestedKeep: keep, copies: group.urls
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
