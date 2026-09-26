import CryptoKit
import Darwin
import Foundation

final class TrashRestoreService: @unchecked Sendable {
    static let shared = TrashRestoreService(recordsDirectory: FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.seeker.app/TrashOrigins", isDirectory: true))

    private struct Identity: Codable, Equatable {
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }

    private struct Record: Codable {
        let originalURL: URL
        let identity: Identity
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private let recordsDirectory: URL
    private let lock = NSLock()

    init(recordsDirectory: URL) {
        self.recordsDirectory = recordsDirectory
    }

    @discardableResult
    func trash(_ source: URL) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard !TrashDiagnostics.isInsideTrash(source) else {
            throw Failure("This item is already in the Trash. Use Put Back to restore it.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
        var resultingURL: NSURL?
        try fm.trashItem(at: source, resultingItemURL: &resultingURL)
        guard let target = resultingURL as URL? else {
            throw Failure("The system did not return a Trash location for \(source.lastPathComponent). Check the Trash before retrying.")
        }
        do {
            let record = Record(originalURL: source, identity: try identity(of: target))
            try PropertyListEncoder().encode(record).write(to: recordURL(for: target), options: .atomic)
        } catch {
            let saveError = error.localizedDescription
            do {
                try fm.moveItem(at: target, to: source)
            } catch {
                throw Failure("Could not save the original location (\(saveError)) or restore the item (\(error.localizedDescription)). The item remains at \(target.path).")
            }
            throw Failure("Could not save the original location: \(saveError). The item was returned to \(source.path).")
        }
        return target
    }

    func originalURL(for trashed: URL) throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return try readOriginalURL(for: trashed)
    }

    @discardableResult
    func restore(_ trashed: URL, to destination: URL? = nil) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard TrashDiagnostics.isTrashDirectory(trashed.deletingLastPathComponent()) else {
            throw Failure("Only items in the Trash can be put back.")
        }
        guard let target = try destination ?? readOriginalURL(for: trashed) else {
            throw Failure("The original location is unknown. Choose a folder to restore this item.")
        }
        guard !TrashDiagnostics.isInsideTrash(target) else {
            throw Failure("Choose a restore location outside the Trash.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // moveItem refuses existing destinations, including dangling symlinks.
        try fm.moveItem(at: trashed, to: target)
        do {
            try fm.removeItem(at: recordURL(for: trashed))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Items trashed outside Seeker have no origin record.
        } catch {
            print("[Seeker] Restored \(target.path), but could not remove its Trash origin record: \(error)")
        }
        return target
    }

    private func readOriginalURL(for trashed: URL) throws -> URL? {
        let data: Data
        do {
            data = try Data(contentsOf: recordURL(for: trashed))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let record = try PropertyListDecoder().decode(Record.self, from: data)
        // A filename can be reused after Finder empties or restores an item.
        guard record.identity == (try identity(of: trashed)) else { return nil }
        return record.originalURL
    }

    private func recordURL(for trashed: URL) -> URL {
        let path = trashed.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(trashed.lastPathComponent).path
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return recordsDirectory.appendingPathComponent(key + ".plist")
    }

    private func identity(of url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return Identity(inode: UInt64(info.st_ino), birthSeconds: Int64(info.st_birthtimespec.tv_sec),
                        birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
}
