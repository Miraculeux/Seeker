import Foundation

/// Minimal FLAC metadata writer.
/// Inserts/updates Vorbis Comment and Picture metadata blocks.
enum FLACWriter {
    enum WriteError: Error {
        case notAFLACFile
        case headerReadFailed
        case ioFailure
    }

    /// Streaming rewrite: reads the FLAC stream marker + metadata block
    /// headers (only \u2014 not the audio frames) from `url`, builds a fresh
    /// metadata section with updated tags, then streams the original
    /// audio frames into a sibling temp file via `FileHandle` and atomic-
    /// renames over the source.
    ///
    /// Avoids the previous `Data(contentsOf:)` + `Array(audioData)` +
    /// per-block in-memory rebuild, which for a 50 MB FLAC pushed peak
    /// resident memory by ~150 MB. Worst-case allocation here is the
    /// metadata header tail (\u226410 KB typical, dominated by cover art
    /// when present).
    @discardableResult
    static func rewriteFile(
        at url: URL,
        title: String?,
        artist: String?,
        album: String?,
        imageData: Data?,
        imageMimeType: String?
    ) throws -> Bool {
        let read: FileHandle
        do {
            read = try FileHandle(forReadingFrom: url)
        } catch {
            throw WriteError.headerReadFailed
        }
        defer { try? read.close() }

        // Verify "fLaC" stream marker.
        guard let marker = try? read.read(upToCount: 4), marker.count == 4,
              marker[0] == 0x66, marker[1] == 0x4C, marker[2] == 0x61, marker[3] == 0x43 else {
            throw WriteError.notAFLACFile
        }

        // Walk metadata block headers, capturing block bodies in memory but
        // *not* the audio frames that follow.
        var keptBlocks: [(type: UInt8, data: Data)] = []
        var isLast = false
        while !isLast {
            guard let hdr = try? read.read(upToCount: 4), hdr.count == 4 else {
                throw WriteError.headerReadFailed
            }
            isLast = (hdr[0] & 0x80) != 0
            let blockType = hdr[0] & 0x7F
            let blockSize = Int(hdr[1]) << 16 | Int(hdr[2]) << 8 | Int(hdr[3])

            if blockType == 4 || blockType == 6 {
                // Skip existing Vorbis Comment / Picture blocks \u2014 we'll
                // emit fresh ones below. Seek past them so we don't allocate.
                try? read.seek(toOffset: read.offsetInFile + UInt64(blockSize))
            } else {
                guard let body = try? read.read(upToCount: blockSize),
                      body.count == blockSize else {
                    throw WriteError.headerReadFailed
                }
                keptBlocks.append((type: blockType, data: body))
            }
        }

        // Audio frames begin at the current read offset.
        let audioStart = read.offsetInFile

        // Append fresh Vorbis Comment + (optional) Picture blocks.
        let vorbis = buildVorbisComment(title: title, artist: artist, album: album)
        keptBlocks.append((type: 4, data: vorbis))
        if let img = imageData, !img.isEmpty {
            let pic = buildPictureBlock(imageData: img, mimeType: imageMimeType ?? "image/jpeg")
            keptBlocks.append((type: 6, data: pic))
        }

        // Materialise the new header section in memory (small \u2014 dominated
        // by any embedded cover art, which we already had in `img`).
        var header = Data()
        header.reserveCapacity(4 + keptBlocks.reduce(0) { $0 + 4 + $1.data.count })
        header.append(contentsOf: [0x66, 0x4C, 0x61, 0x43])
        for (i, block) in keptBlocks.enumerated() {
            let last = (i == keptBlocks.count - 1)
            var b = block.type
            if last { b |= 0x80 }
            header.append(b)
            let size = block.data.count
            header.append(UInt8((size >> 16) & 0xFF))
            header.append(UInt8((size >> 8) & 0xFF))
            header.append(UInt8(size & 0xFF))
            header.append(block.data)
        }

        // Write to a sibling temp file, then atomic-rename. Matches the
        // pattern in `ExifEditor.writeImage` and avoids leaving a partially-
        // written file at `url` if something fails mid-stream.
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(
            "." + url.lastPathComponent + ".seeker.tmp.\(UUID().uuidString)"
        )
        let fm = FileManager.default
        guard fm.createFile(atPath: tempURL.path, contents: nil) else {
            throw WriteError.ioFailure
        }
        let write: FileHandle
        do {
            write = try FileHandle(forWritingTo: tempURL)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw WriteError.ioFailure
        }

        do {
            try write.write(contentsOf: header)

            // Stream audio frames in 1 MiB chunks. Reposition the read
            // handle to the end of the source's metadata section first.
            try read.seek(toOffset: audioStart)
            let chunkSize = 1 << 20
            while true {
                guard let chunk = try? read.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                try write.write(contentsOf: chunk)
            }
            try write.close()
        } catch {
            try? write.close()
            try? fm.removeItem(at: tempURL)
            throw WriteError.ioFailure
        }

        // Replace original with the rewritten temp file.
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw WriteError.ioFailure
        }
        return true
    }

    /// In-memory variant. Retained for compatibility / future callers that
    /// already hold the full FLAC bytes; for files on disk prefer
    /// `rewriteFile(at:...)` which streams the audio frames and avoids
    /// the multi-x peak-memory cost on large tracks.
    static func writeMetadata(
        to audioData: Data,
        title: String?,
        artist: String?,
        album: String?,
        imageData: Data?,
        imageMimeType: String?
    ) -> Data? {
        // Verify FLAC stream marker "fLaC". Index `Data` directly so we
        // don't allocate an intermediate `[UInt8]` copy.
        guard audioData.count > 4 else { return nil }
        let base = audioData.startIndex
        guard audioData[base] == 0x66, audioData[base + 1] == 0x4C,
              audioData[base + 2] == 0x61, audioData[base + 3] == 0x43 else {
            return nil
        }

        // Parse existing metadata blocks
        var offset = base + 4
        var metadataBlocks: [(type: UInt8, data: Data)] = []
        var isLast = false

        while !isLast && offset + 4 <= audioData.endIndex {
            let blockHeader = audioData[offset]
            isLast = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F
            let blockSize = Int(audioData[offset + 1]) << 16
                | Int(audioData[offset + 2]) << 8
                | Int(audioData[offset + 3])
            offset += 4

            guard offset + blockSize <= audioData.endIndex else { break }

            // Keep all blocks except existing Vorbis Comment (4) and Picture (6)
            if blockType != 4 && blockType != 6 {
                metadataBlocks.append((type: blockType, data: audioData.subdata(in: offset..<(offset + blockSize))))
            }
            offset += blockSize
        }

        // Build new Vorbis Comment block
        let vorbisComment = buildVorbisComment(title: title, artist: artist, album: album)
        metadataBlocks.append((type: 4, data: vorbisComment))

        // Build Picture block if we have image data
        if let imageData = imageData, !imageData.isEmpty {
            let pictureBlock = buildPictureBlock(imageData: imageData, mimeType: imageMimeType ?? "image/jpeg")
            metadataBlocks.append((type: 6, data: pictureBlock))
        }

        // Reconstruct the FLAC file. Reserve up-front to avoid the geometric
        // re-allocation pattern when appending the audio payload.
        let audioTailCount = audioData.endIndex - offset
        var result = Data()
        result.reserveCapacity(4 + metadataBlocks.reduce(0) { $0 + 4 + $1.data.count } + audioTailCount)
        result.append(contentsOf: [0x66, 0x4C, 0x61, 0x43]) // "fLaC"

        for (i, block) in metadataBlocks.enumerated() {
            let isLastBlock = (i == metadataBlocks.count - 1)
            var header = block.type
            if isLastBlock { header |= 0x80 }
            result.append(header)

            let size = block.data.count
            result.append(UInt8((size >> 16) & 0xFF))
            result.append(UInt8((size >> 8) & 0xFF))
            result.append(UInt8(size & 0xFF))
            result.append(block.data)
        }

        // Append audio frames (everything after metadata) by slicing the
        // original Data \u2014 cheap, since `Data` slices share storage.
        if offset < audioData.endIndex {
            result.append(audioData.subdata(in: offset..<audioData.endIndex))
        }

        return result
    }

    private static func buildVorbisComment(title: String?, artist: String?, album: String?) -> Data {
        var data = Data()

        // Vendor string
        let vendor = "ncmdump-swift"
        appendLE32(&data, UInt32(vendor.utf8.count))
        data.append(contentsOf: Array(vendor.utf8))

        // Count comments
        var comments: [String] = []
        if let title = title, !title.isEmpty { comments.append("TITLE=\(title)") }
        if let artist = artist, !artist.isEmpty { comments.append("ARTIST=\(artist)") }
        if let album = album, !album.isEmpty { comments.append("ALBUM=\(album)") }

        appendLE32(&data, UInt32(comments.count))

        for comment in comments {
            let utf8 = Array(comment.utf8)
            appendLE32(&data, UInt32(utf8.count))
            data.append(contentsOf: utf8)
        }

        return data
    }

    private static func buildPictureBlock(imageData: Data, mimeType: String) -> Data {
        var data = Data()

        // Picture type: 3 = Cover (front)
        appendBE32(&data, 3)

        // MIME type
        let mimeBytes = Array(mimeType.utf8)
        appendBE32(&data, UInt32(mimeBytes.count))
        data.append(contentsOf: mimeBytes)

        // Description (empty)
        appendBE32(&data, 0)

        // Width, height, color depth, indexed colors (0 = unknown)
        appendBE32(&data, 0)
        appendBE32(&data, 0)
        appendBE32(&data, 0)
        appendBE32(&data, 0)

        // Picture data
        appendBE32(&data, UInt32(imageData.count))
        data.append(imageData)

        return data
    }

    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendBE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
