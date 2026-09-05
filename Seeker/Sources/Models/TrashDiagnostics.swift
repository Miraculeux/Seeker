import Darwin
import Foundation

struct TrashDiagnostic: Sendable {
    enum Kind: Sendable {
        case permission
        case busy
        case readOnly
        case fileSystem
        case other
    }

    let itemName: String
    let volumeName: String
    let volumePath: String
    let fileSystem: String
    let kind: Kind
    let detail: String

    var offersFullDiskAccess: Bool { kind == .permission }
    var offersDiskUtility: Bool { kind == .fileSystem }

    var message: String {
        "\(itemName) — \(volumeName) (\(fileSystem))\n\(detail)"
    }
}

enum TrashDiagnostics {
    static func trashItemURLs() -> [URL] {
        let fileManager = FileManager.default
        var roots = [fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")]
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let userID = String(getuid())
        if let volumes = try? fileManager.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            roots += volumes.map {
                $0.appendingPathComponent(".Trashes", isDirectory: true)
                    .appendingPathComponent(userID, isDirectory: true)
            }
        }

        var seenPaths = Set<String>()
        return roots.flatMap { root -> [URL] in
            guard seenPaths.insert(root.standardizedFileURL.path).inserted else { return [] }
            return (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
        }
    }

    static func diagnose(url: URL, error: Error) -> TrashDiagnostic {
        let volumeURL = volumeURL(containing: url)
        let values = try? volumeURL.resourceValues(forKeys: [
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsReadOnlyKey,
            .volumeNameKey,
        ])
        let fileSystem = values?.volumeLocalizedFormatDescription ?? "Unknown file system"
        let volumeName = values?.volumeName ?? volumeURL.lastPathComponent
        let errors = errorChain(error as NSError)

        let kind: TrashDiagnostic.Kind
        let detail: String
        if errors.contains(where: isPermissionError) {
            kind = .permission
            detail = "Seeker does not have permission to remove this item. Grant Full Disk Access, then try again."
        } else if values?.volumeIsReadOnly == true || containsPOSIXError(EROFS, in: errors) {
            kind = .readOnly
            detail = "The volume is mounted read-only. Remount it with write access before emptying Trash."
        } else if containsPOSIXError(EBUSY, in: errors) || containsPOSIXError(ETXTBSY, in: errors) {
            kind = .busy
            detail = "The item is actively in use. Close apps, Finder previews, and Terminal sessions using this volume, then retry."
        } else if containsPOSIXError(ENOTEMPTY, in: errors) {
            kind = .fileSystem
            if fileSystem.localizedCaseInsensitiveContains("NTFS") {
                detail = "The directory reports that it is not empty but its contents cannot be enumerated. The NTFS directory index may be inconsistent. Run First Aid or Windows chkdsk /f; Seeker will not force a filesystem repair."
            } else {
                detail = "The directory reports hidden or inconsistent entries. Run First Aid for this volume before retrying."
            }
        } else {
            kind = .other
            detail = error.localizedDescription
        }

        return TrashDiagnostic(
            itemName: url.lastPathComponent,
            volumeName: volumeName,
            volumePath: volumeURL.path,
            fileSystem: fileSystem,
            kind: kind,
            detail: detail
        )
    }

    private static func volumeURL(containing url: URL) -> URL {
        let components = url.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            return URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2])
        }
        return URL(fileURLWithPath: "/")
    }

    private static func errorChain(_ root: NSError) -> [NSError] {
        var errors: [NSError] = []
        var current: NSError? = root
        while let error = current {
            errors.append(error)
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }

    private static func containsPOSIXError(_ code: Int32, in errors: [NSError]) -> Bool {
        errors.contains { $0.domain == NSPOSIXErrorDomain && $0.code == Int(code) }
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(EACCES) || error.code == Int(EPERM)
        }
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == NSFileReadNoPermissionError
            || error.code == NSFileWriteNoPermissionError
    }
}