import Foundation
import UniformTypeIdentifiers
import AppKit

struct FileItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let isHidden: Bool
    let isPackage: Bool

    /// Directories under ~ that trigger TCC prompts when accessed
    private static let tccProtectedNames: Set<String> = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]

    private static let homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

    init(url: URL) {
        self.id = url.absoluteString
        self.url = url
        self.name = url.lastPathComponent

        // Check if this is a TCC-protected directory under ~ to avoid prompts
        let parentPath = url.deletingLastPathComponent().path
        if parentPath == FileItem.homeDirectory && FileItem.tccProtectedNames.contains(url.lastPathComponent) {
            self.isDirectory = true
            self.fileSize = 0
            self.modificationDate = nil
            self.creationDate = nil
            self.isHidden = false
            self.isPackage = false
            return
        }

        // Use lstat to check directory status without triggering TCC prompts
        var statInfo = stat()
        let isDir: Bool
        let size: Int64
        let mDate: Date?
        let cDate: Date?
        let hidden: Bool

        if lstat(url.path, &statInfo) == 0 {
            isDir = (statInfo.st_mode & S_IFMT) == S_IFDIR
            size = isDir ? 0 : Int64(statInfo.st_size)
            mDate = Date(timeIntervalSince1970: Double(statInfo.st_mtimespec.tv_sec))
            cDate = Date(timeIntervalSince1970: Double(statInfo.st_birthtimespec.tv_sec))
            hidden = url.lastPathComponent.hasPrefix(".")
        } else {
            isDir = false
            size = 0
            mDate = nil
            cDate = nil
            hidden = url.lastPathComponent.hasPrefix(".")
        }

        self.isDirectory = isDir
        self.fileSize = size
        self.modificationDate = mDate
        self.creationDate = cDate
        self.isHidden = hidden
        self.isPackage = isDir && NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    /// Native macOS file icon, matching Finder's display
    var nsIcon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDate: String {
        guard let date = modificationDate else { return "--" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var typeDescription: String {
        if isDirectory { return "Folder" }
        if let utType = UTType(filenameExtension: url.pathExtension) {
            return utType.localizedDescription ?? url.pathExtension.uppercased()
        }
        return url.pathExtension.uppercased()
    }

    var displayName: String {
        let showExtensions = UserDefaults.standard.object(forKey: "showFileExtensions") as? Bool ?? false
        if showExtensions || url.pathExtension.isEmpty {
            return name
        }
        if !showExtensions && isDirectory && !isPackage {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    var isNCMFile: Bool {
        url.pathExtension.lowercased() == "ncm"
    }

    /// Shallow check: does this folder contain any .ncm files?
    var containsNCMFiles: Bool {
        guard isDirectory else { return false }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return contents.contains { $0.pathExtension.lowercased() == "ncm" }
    }
}
