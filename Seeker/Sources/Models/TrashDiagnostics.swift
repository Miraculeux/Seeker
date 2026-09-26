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
    struct Listing: Sendable {
        var urls: [URL] = []
        var errors: [String] = []
    }

    static func isTrashLocation(_ url: URL) -> Bool {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return url.standardizedFileURL.path == trash.standardizedFileURL.path
            || url.resolvingSymlinksInPath().path == trash.resolvingSymlinksInPath().path
    }

    static func isTrashDirectory(_ url: URL) -> Bool {
        if isTrashLocation(url) { return true }
        let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return components.count == 5 && components[1] == "Volumes"
            && components[3] == ".Trashes" && components[4] == String(getuid())
    }

    static func isInsideTrash(_ url: URL) -> Bool {
        if isTrashDirectory(url) { return true }
        var directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        while directory.path != "/" {
            if isTrashDirectory(directory) { return true }
            directory.deleteLastPathComponent()
        }
        return false
    }

    static func trashRoots() throws -> [URL] {
        let fileManager = FileManager.default
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let userID = String(getuid())
        let volumes = try fileManager.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return [fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")]
            + volumes.map {
                $0.appendingPathComponent(".Trashes", isDirectory: true)
                    .appendingPathComponent(userID, isDirectory: true)
            }
    }

    static func listing() -> Listing {
        do {
            return listing(roots: try trashRoots())
        } catch {
            var result = listing(roots: [
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            ])
            result.errors.append("Could not locate external Trash folders: \(error.localizedDescription)")
            return result
        }
    }

    static func listing(roots: [URL]) -> Listing {
        var result = Listing()
        var seenPaths = Set<String>()
        for root in roots {
            let directory = root.resolvingSymlinksInPath().standardizedFileURL
            guard seenPaths.insert(directory.path).inserted else { continue }
            do {
                result.urls += try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: FileItem.prefetchKeys,
                    options: []
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // Volumes with no trashed items need not have a Trash directory yet.
                continue
            } catch {
                result.errors.append("Could not read Trash at \(root.path): \(error.localizedDescription)")
            }
        }
        return result
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