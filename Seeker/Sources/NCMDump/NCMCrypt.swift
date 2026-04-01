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

    public let filepath: String
    public private(set) var dumpFilepath: String = ""
    public private(set) var format: AudioFormat = .mp3
    public private(set) var metadata: MusicMetadata?
    public private(set) var imageData: Data?
    private var keyBox: [UInt8] = Array(repeating: 0, count: 256)
    private var fileHandle: FileHandle

    public init(path: String) throws {
        self.filepath = path

        guard FileManager.default.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            throw NCMCryptError.cannotOpenFile(path)
        }
        self.fileHandle = handle

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
        guard keyLen > 0 else { throw NCMCryptError.brokenNCMFile }

        var keyData = try readBytes(count: Int(keyLen))
        for i in 0..<keyData.count {
            keyData[i] ^= 0x64
        }

        let decryptedKey = AESHelper.ecbDecrypt(key: Self.coreKey, data: keyData)
        // Skip first 17 bytes ("neteasecloudmusic")
        let rc4Key = Array(decryptedKey.dropFirst(17))
        buildKeyBox(key: rc4Key)

        // Read metadata
        let metaLen = try readUInt32()
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

        if imageLen > 0 {
            self.imageData = Data(try readBytes(count: Int(imageLen)))
        } else {
            fputs("[Warn] '\(path)' missing album image!\n", stderr)
        }

        // Skip remaining cover frame data
        let remaining = Int(coverFrameLen) - Int(imageLen)
        if remaining > 0 {
            try skip(count: remaining)
        }
    }

    public mutating func dump(outputDir: String = "") throws {
        let sourceURL = URL(fileURLWithPath: filepath)
        var outputURL: URL

        if outputDir.isEmpty {
            outputURL = sourceURL
        } else {
            outputURL = URL(fileURLWithPath: outputDir).appendingPathComponent(sourceURL.lastPathComponent)
        }

        let bufferSize = 0x8000
        var outputData = Data()
        var formatDetected = false

        while true {
            let chunk: [UInt8]
            do {
                chunk = try readBytes(count: bufferSize)
            } catch {
                break // EOF
            }

            var decrypted = chunk
            for i in 0..<decrypted.count {
                let j = (i + 1) & 0xFF
                decrypted[i] ^= keyBox[(Int(keyBox[j]) + Int(keyBox[(Int(keyBox[j]) + j) & 0xFF])) & 0xFF]
            }

            if !formatDetected {
                // Detect format from first bytes: ID3 = MP3, else FLAC
                if decrypted.count >= 3 && decrypted[0] == 0x49 && decrypted[1] == 0x44 && decrypted[2] == 0x33 {
                    format = .mp3
                    outputURL = outputURL.deletingPathExtension().appendingPathExtension("mp3")
                } else {
                    format = .flac
                    outputURL = outputURL.deletingPathExtension().appendingPathExtension("flac")
                }
                formatDetected = true
            }

            outputData.append(contentsOf: decrypted)
        }

        dumpFilepath = outputURL.path
        try outputData.write(to: outputURL)
    }

    public func fixMetadata() {
        // Without TagLib, we use a lightweight approach:
        // For MP3: write ID3v2 tags
        // For FLAC: write Vorbis comments
        guard metadata != nil || imageData != nil else { return }

        guard FileManager.default.fileExists(atPath: dumpFilepath),
              let existingData = try? Data(contentsOf: URL(fileURLWithPath: dumpFilepath)) else {
            return
        }

        switch format {
        case .mp3:
            if let tagged = ID3Writer.writeTag(
                to: existingData,
                title: metadata?.name,
                artist: metadata?.artist,
                album: metadata?.album,
                imageData: imageData,
                imageMimeType: mimeType(for: imageData)
            ) {
                try? tagged.write(to: URL(fileURLWithPath: dumpFilepath))
            }
        case .flac:
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
    }

    // MARK: - Private helpers

    private mutating func buildKeyBox(key: [UInt8]) {
        for i in 0..<256 {
            keyBox[i] = UInt8(i)
        }

        var lastByte: UInt8 = 0
        var keyOffset = 0

        for i in 0..<256 {
            let swap = keyBox[i]
            let c = UInt8((Int(swap) + Int(lastByte) + Int(key[keyOffset])) & 0xFF)
            keyOffset += 1
            if keyOffset >= key.count { keyOffset = 0 }
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
        let data = fileHandle.readData(ofLength: count)
        guard data.count > 0 else { throw NCMCryptError.readError }
        return Array(data)
    }

    private func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    private func skip(count: Int) throws {
        let offset = fileHandle.offsetInFile
        fileHandle.seek(toFileOffset: offset + UInt64(count))
    }
}
