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

    init(url: URL) {
        self.id = url.absoluteString
        self.url = url
        self.name = url.lastPathComponent

        let resourceValues = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .isHiddenKey, .isPackageKey
        ])

        self.isDirectory = resourceValues?.isDirectory ?? false
        self.fileSize = Int64(resourceValues?.fileSize ?? 0)
        self.modificationDate = resourceValues?.contentModificationDate
        self.creationDate = resourceValues?.creationDate
        self.isHidden = resourceValues?.isHidden ?? false
        self.isPackage = resourceValues?.isPackage ?? false
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
        if showExtensions || isDirectory || url.pathExtension.isEmpty {
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
