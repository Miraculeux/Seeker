import Foundation

enum ComputerLocation {
    static let url = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    static let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    static let volumeKeys: Set<URLResourceKey> = Set(FileItem.prefetchKeys).union([
        .volumeNameKey, .volumeIsBrowsableKey, .volumeIsInternalKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey,
    ])

    static func isRoot(_ location: URL) -> Bool {
        location.isFileURL && location.standardizedFileURL.path == url.path
    }

    static func title(for location: URL) -> String {
        if isRoot(location) { return name }
        if location.path == "/" { return FileManager.default.displayName(atPath: "/") }
        return location.lastPathComponent
    }

    static func isHiddenMount(_ location: URL) -> Bool {
        location.pathComponents.contains { $0.hasPrefix(".") }
    }

    static func volumes() throws -> [URL] {
        // Unlike listing /Volumes, this excludes staging directories such as
        // .timemachine and includes the startup disk at its real root URL.
        guard let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeKeys),
            options: [.skipHiddenVolumes]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        return try mounted.filter { volume in
            try Task.checkCancellation()
            guard !isHiddenMount(volume) else { return false }
            let values = try volume.resourceValues(forKeys: volumeKeys)
            return values.isHidden != true && values.volumeIsBrowsable != false
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func files() throws -> [FileItem] {
        try volumes().map { volume in
            try Task.checkCancellation()
            let values = try volume.resourceValues(forKeys: volumeKeys)
            return FileItem(url: volume, resourceValues: values, name: values.volumeName)
        }
    }
}
