import Foundation

/// Minimal FLAC metadata writer.
/// Inserts/updates Vorbis Comment and Picture metadata blocks.
enum FLACWriter {
    static func writeMetadata(
        to audioData: Data,
        title: String?,
        artist: String?,
        album: String?,
        imageData: Data?,
        imageMimeType: String?
    ) -> Data? {
        let bytes = Array(audioData)
        // Verify FLAC stream marker "fLaC"
        guard bytes.count > 4,
              bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            return nil
        }

        // Parse existing metadata blocks
        var offset = 4
        var metadataBlocks: [(type: UInt8, data: Data)] = []
        var isLast = false

        while !isLast && offset + 4 <= bytes.count {
            let blockHeader = bytes[offset]
            isLast = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F
            let blockSize = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4

            guard offset + blockSize <= bytes.count else { break }

            let blockData = Data(bytes[offset..<(offset + blockSize)])
            // Keep all blocks except existing Vorbis Comment (4) and Picture (6) — we'll replace those
            if blockType != 4 && blockType != 6 {
                metadataBlocks.append((type: blockType, data: blockData))
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

        // Reconstruct the FLAC file
        var result = Data()
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

        // Append audio frames (everything after metadata)
        if offset < bytes.count {
            result.append(Data(bytes[offset...]))
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
