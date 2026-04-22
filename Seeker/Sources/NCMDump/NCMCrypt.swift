import Foundation
import CommonCrypto

public enum NCMCryptError: LocalizedError {
    case cannotOpenFile(String)
    case notNCMFile
    case cannotSeekFile
    case brokenNCMFile
    case readError

    public var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path): return "Can't open file: \(path)"
        case .notNCMFile: return "Not netease protected file"
        case .cannotSeekFile: return "Can't seek file"
        case .brokenNCMFile: return "Broken NCM file"
        case .readError: return "Can't read file"
        }
    }
}

public struct NCMCrypt {
    public enum AudioFormat {
        case mp3, flac
    }

    private static let coreKey: [UInt8] = [
        0x68, 0x7A, 0x48, 0x52, 0x41, 0x6D, 0x73, 0x6F,
        0x35, 0x6B, 0x49, 0x6E, 0x62, 0x61, 0x78, 0x57
    ]

    private static let modifyKey: [UInt8] = [
        0x23, 0x31, 0x34, 0x6C, 0x6A, 0x6B, 0x5F, 0x21,
        0x5C, 0x5D, 0x26, 0x30, 0x55, 0x3C, 0x27, 0x28
    ]

    private static let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    // Per-field hard caps to defend against crafted NCM headers that
    // declare absurd lengths and try to allocate gigabytes / crash.
    private static let maxKeyLen: UInt32 = 4096          // wrapped RC4 key
    private static let maxMetaLen: UInt32 = 1 << 20      // 1 MiB JSON metadata
    private static let maxImageLen: UInt32 = 32 << 20    // 32 MiB album art
    private static let maxCoverFrameLen: UInt32 = 32 << 20

    public let filepath: String
    public private(set) var dumpFilepath: String = ""
    public private(set) var format: AudioFormat = .mp3
    public private(set) var metadata: MusicMetadata?
    public private(set) var imageData: Data?
    private var keyBox: [UInt8] = Array(repeating: 0, count: 256)
    private var fileHandle: FileHandle
    private let fileSize: UInt64

    public init(path: String) throws {
        self.filepath = path

        guard FileManager.default.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            throw NCMCryptError.cannotOpenFile(path)
        }
        self.fileHandle = handle
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        self.fileSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

        // Validate NCM header: "CTNE" + "MADF"
        let header = try readBytes(count: 8)
        let magic1 = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        let magic2 = UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24
        guard magic1 == 0x4E455443, magic2 == 0x4D414446 else {
            throw NCMCryptError.notNCMFile
        }

        // Skip 2 bytes (gap)
        try skip(count: 2)

        // Read key data
        let keyLen = try readUInt32()
        guard keyLen > 0, keyLen <= Self.maxKeyLen else {
            throw NCMCryptError.brokenNCMFile
        }

        var keyData = try readBytes(count: Int(keyLen))
        for i in 0..<keyData.count {
            keyData[i] ^= 0x64
        }

        let decryptedKey = AESHelper.ecbDecrypt(key: Self.coreKey, data: keyData)
        // Skip first 17 bytes ("neteasecloudmusic"); reject if too short.
        guard decryptedKey.count > 17 else { throw NCMCryptError.brokenNCMFile }
        let rc4Key = decryptedKey.dropFirst(17)
        guard !rc4Key.isEmpty else { throw NCMCryptError.brokenNCMFile }
        buildKeyBox(key: rc4Key)

        // Read metadata
        let metaLen = try readUInt32()
        guard metaLen <= Self.maxMetaLen else { throw NCMCryptError.brokenNCMFile }
        if metaLen > 0 {
            var modifyData = try readBytes(count: Int(metaLen))
            for i in 0..<modifyData.count {
                modifyData[i] ^= 0x63
            }

            // Skip first 22 bytes "163 key(Don't modify):" then base64 decode
            let base64Str = String(bytes: modifyData.dropFirst(22), encoding: .utf8) ?? ""
            if let base64Data = Data(base64Encoded: base64Str) {
                let decrypted = AESHelper.ecbDecrypt(key: Self.modifyKey, data: Array(base64Data))
                // Skip "music:" prefix (6 bytes)
                let jsonBytes = Array(decrypted.dropFirst(6))
                if let jsonStr = String(bytes: jsonBytes, encoding: .utf8),
                   let jsonData = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    self.metadata = MusicMetadata(json: json)
                }
            }
        } else {
            fputs("[Warn] '\(path)' missing metadata, can't fix some information!\n", stderr)
        }

        // Skip CRC32 (4 bytes) + unused byte (1 byte) = 5 bytes
        try skip(count: 5)

        // Read cover image
        let coverFrameLen = try readUInt32()
        let imageLen = try readUInt32()
        guard coverFrameLen <= Self.maxCoverFrameLen,
              imageLen <= Self.maxImageLen,
              imageLen <= coverFrameLen else {
            throw NCMCryptError.brokenNCMFile
        }

        if imageLen > 0 {
            self.imageData = Data(try readBytes(count: Int(imageLen)))
        } else {
            fputs("[Warn] '\(path)' missing album image!\n", stderr)
        }

        // Skip remaining cover frame data (imageLen <= coverFrameLen above)
        let remaining = Int(coverFrameLen) - Int(imageLen)
        if remaining > 0 {
            try skip(count: remaining)
        }
    }

    public mutating func dump(outputDir: String = "") throws {
        let sourceURL = URL(fileURLWithPath: filepath)
        var outputURL: URL = outputDir.isEmpty
            ? sourceURL
            : URL(fileURLWithPath: outputDir).appendingPathComponent(sourceURL.lastPathComponent)

        // 256 KiB — large enough to amortize syscall + write overhead, small
        // enough not to bloat working set when dumping many files in parallel.
        // MUST be a multiple of 256 (the RC4-like keystream period used by
        // `decryptInPlace`) so chunk-local indexing matches global stream
        // semantics.
        let bufferSize = 1 << 18

        // --- Pass 1: read & decrypt the first chunk to detect format. -------
        let firstAvail = readableChunkSize(target: bufferSize)
        guard firstAvail > 0 else { throw NCMCryptError.brokenNCMFile }
        var firstChunk = fileHandle.readData(ofLength: firstAvail)
        guard !firstChunk.isEmpty else { throw NCMCryptError.brokenNCMFile }
        decryptInPlace(&firstChunk)

        let isMP3 = firstChunk.count >= 3
            && firstChunk[0] == 0x49 && firstChunk[1] == 0x44 && firstChunk[2] == 0x33
        format = isMP3 ? .mp3 : .flac
        outputURL = outputURL.deletingPathExtension()
            .appendingPathExtension(isMP3 ? "mp3" : "flac")
        dumpFilepath = outputURL.path

        // --- Open output handle (truncate). ---------------------------------
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        fm.createFile(atPath: outputURL.path, contents: nil)
        guard let writeHandle = try? FileHandle(forWritingTo: outputURL) else {
            throw NCMCryptError.cannotOpenFile(outputURL.path)
        }
        defer { try? writeHandle.close() }

        // --- For MP3: write the new ID3v2 tag now and skip the source's
        //     existing leading ID3v2 inline (avoids the read-modify-write
        //     rewrite that the original `fixMetadata` did). ------------------
        var bytesToSkip = 0  // remaining bytes of source ID3v2 to discard
        if isMP3 {
            if let tagHeader = buildID3v2HeaderData() {
                try writeHandle.write(contentsOf: tagHeader)
            }
            bytesToSkip = id3v2TotalSize(in: firstChunk) ?? 0
        }

        // Helper to write a (possibly truncated) chunk respecting `bytesToSkip`.
        func writeChunkRespectingSkip(_ chunk: Data) throws {
            if bytesToSkip == 0 {
                try writeHandle.write(contentsOf: chunk)
                return
            }
            if bytesToSkip >= chunk.count {
                bytesToSkip -= chunk.count
                return
            }
            let trimmed = chunk.subdata(in: bytesToSkip..<chunk.count)
            bytesToSkip = 0
            try writeHandle.write(contentsOf: trimmed)
        }

        try writeChunkRespectingSkip(firstChunk)

        // --- Pass 2: stream-decrypt remaining chunks straight to disk. ------
        while true {
            let avail = readableChunkSize(target: bufferSize)
            if avail == 0 { break }
            var chunk = fileHandle.readData(ofLength: avail)
            if chunk.isEmpty { break }
            decryptInPlace(&chunk)
            try writeChunkRespectingSkip(chunk)
        }
    }

    public func fixMetadata() {
        // Without TagLib, we use a lightweight approach:
        // For MP3: tag is already written inline by `dump()`, no work needed.
        // For FLAC: read the (small) file, splice in metadata blocks, re-write.
        guard format == .flac else { return }
        guard metadata != nil || imageData != nil else { return }

        guard FileManager.default.fileExists(atPath: dumpFilepath),
              let existingData = try? Data(contentsOf: URL(fileURLWithPath: dumpFilepath)) else {
            return
        }

        if let tagged = FLACWriter.writeMetadata(
            to: existingData,
            title: metadata?.name,
            artist: metadata?.artist,
            album: metadata?.album,
            imageData: imageData,
            imageMimeType: mimeType(for: imageData)
        ) {
            try? tagged.write(to: URL(fileURLWithPath: dumpFilepath))
        }
    }

    // MARK: - Streaming helpers

    /// Returns the next chunk size to read, capped at `target` and at the
    /// remaining bytes in the source file.
    private func readableChunkSize(target: Int) -> Int {
        guard fileSize > 0 else { return target }
        let offset = fileHandle.offsetInFile
        if offset >= fileSize { return 0 }
        return Int(min(UInt64(target), fileSize - offset))
    }

    /// Decrypt `chunk` in place. The keystream period is 256 and resets each
    /// chunk; `dump` ensures non-final chunk sizes are multiples of 256 so
    /// chunk-local indexing matches global stream semantics. Uses unsafe
    /// pointer access to skip Swift array bounds checks in the hot loop.
    private func decryptInPlace(_ chunk: inout Data) {
        chunk.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            keyBox.withUnsafeBufferPointer { kb in
                guard let kbBase = kb.baseAddress else { return }
                for i in 0..<count {
                    let j = (i + 1) & 0xFF
                    let a = Int(kbBase[j])
                    let b = Int(kbBase[(a + j) & 0xFF])
                    base[i] ^= kbBase[(a + b) & 0xFF]
                }
            }
        }
    }

    /// Build the ID3v2.3 header + frames for the current `metadata`/`imageData`,
    /// without any audio payload. Returns nil if there is nothing to write.
    private func buildID3v2HeaderData() -> Data? {
        // Reuse ID3Writer by handing it an empty audio buffer; it will return
        // tag + (empty audio) which is exactly the tag bytes we need.
        guard metadata != nil || imageData != nil else { return nil }
        let tagged = ID3Writer.writeTag(
            to: Data(),
            title: metadata?.name,
            artist: metadata?.artist,
            album: metadata?.album,
            imageData: imageData,
            imageMimeType: mimeType(for: imageData)
        )
        // `writeTag` returns the input audio when it has nothing to write
        // (i.e. all fields nil/empty). Treat empty result as "no tag".
        return (tagged?.isEmpty == false) ? tagged : nil
    }

    /// If `data` begins with a valid ID3v2 header, return the total tag size
    /// (header + frames) so callers can skip past it. Returns nil otherwise.
    private func id3v2TotalSize(in data: Data) -> Int? {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33,
              data[6] & 0x80 == 0, data[7] & 0x80 == 0,
              data[8] & 0x80 == 0, data[9] & 0x80 == 0 else { return nil }
        let size = (Int(data[6]) << 21) | (Int(data[7]) << 14)
                 | (Int(data[8]) << 7)  |  Int(data[9])
        return size + 10
    }

    // MARK: - Private helpers

    private mutating func buildKeyBox(key: ArraySlice<UInt8>) {
        for i in 0..<256 {
            keyBox[i] = UInt8(i)
        }

        var lastByte: UInt8 = 0
        let keyCount = key.count
        let keyStart = key.startIndex
        var keyOffset = 0

        for i in 0..<256 {
            let swap = keyBox[i]
            let c = UInt8((Int(swap) + Int(lastByte) + Int(key[keyStart + keyOffset])) & 0xFF)
            keyOffset += 1
            if keyOffset >= keyCount { keyOffset = 0 }
            keyBox[i] = keyBox[Int(c)]
            keyBox[Int(c)] = swap
            lastByte = c
        }
    }

    private func mimeType(for data: Data?) -> String {
        guard let data = data, data.count >= 8 else { return "image/jpeg" }
        let bytes = Array(data.prefix(8))
        if bytes == Self.pngHeader {
            return "image/png"
        }
        return "image/jpeg"
    }

    @discardableResult
    private func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw NCMCryptError.brokenNCMFile }
        // Defend against crafted lengths claiming more bytes than the file holds.
        if fileSize > 0 {
            let offset = fileHandle.offsetInFile
            guard UInt64(count) <= fileSize - min(offset, fileSize) else {
                throw NCMCryptError.brokenNCMFile
            }
        }
        let data = fileHandle.readData(ofLength: count)
        guard data.count == count else { throw NCMCryptError.readError }
        return Array(data)
    }

    private func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    private func skip(count: Int) throws {
        guard count >= 0 else { throw NCMCryptError.brokenNCMFile }
        let offset = fileHandle.offsetInFile
        let target = offset + UInt64(count)
        if fileSize > 0, target > fileSize {
            throw NCMCryptError.brokenNCMFile
        }
        fileHandle.seek(toFileOffset: target)
    }
}
