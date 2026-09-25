import Foundation

/// Metadata stays in memory; unchanged media ranges are copied in bounded chunks.
enum MediaFileIO {
    static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        try handle.seek(toOffset: offset)
        var result = Data()
        while result.count < count {
            let chunk = try handle.read(upToCount: min(1 << 20, count - result.count)) ?? Data()
            guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            result.append(chunk)
        }
        return result
    }

    static func copy(_ input: FileHandle, to output: FileHandle,
                     range: Range<UInt64>) throws {
        try input.seek(toOffset: range.lowerBound)
        var remaining = range.upperBound - range.lowerBound
        while remaining > 0 {
            let copied: Int = try autoreleasepool {
                let chunk = try input.read(upToCount: Int(min(1 << 20, remaining))) ?? Data()
                guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(contentsOf: chunk)
                return chunk.count
            }
            remaining -= UInt64(copied)
        }
    }

    static func writeZeros(_ count: UInt64, to output: FileHandle) throws {
        let buffer = Data(count: 1 << 20)
        var remaining = count
        while remaining > 0 {
            let length = Int(min(UInt64(buffer.count), remaining))
            try output.write(contentsOf: buffer.prefix(length))
            remaining -= UInt64(length)
        }
    }

    /// Keep the source intact on every failure, including short reads. Foundation's
    /// replacement preserves the original file's metadata; also retain its mode.
    static func rewrite(_ url: URL,
                        body: (FileHandle, UInt64, FileHandle) throws -> Void) throws {
        let fm = FileManager.default
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try body(input, size, output)
        try output.close()
        if let mode = attributes[.posixPermissions] {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        }
        _ = try fm.replaceItemAt(url, withItemAt: temporary)
    }
}
