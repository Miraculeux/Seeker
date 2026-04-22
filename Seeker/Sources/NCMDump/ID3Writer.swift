import Foundation

/// Minimal ID3v2.3 tag writer for MP3 files.
/// Writes title, artist, album, and front cover image.
enum ID3Writer {
    static func writeTag(
        to audioData: Data,
        title: String?,
        artist: String?,
        album: String?,
        imageData: Data?,
        imageMimeType: String?
    ) -> Data? {
        var frames = Data()

        if let title = title, !title.isEmpty {
            frames.append(textFrame(id: "TIT2", text: title))
        }
        if let artist = artist, !artist.isEmpty {
            frames.append(textFrame(id: "TPE1", text: artist))
        }
        if let album = album, !album.isEmpty {
            frames.append(textFrame(id: "TALB", text: album))
        }
        if let imageData = imageData, !imageData.isEmpty {
            frames.append(pictureFrame(imageData: imageData, mimeType: imageMimeType ?? "image/jpeg"))
        }

        guard !frames.isEmpty else { return audioData }

        // Build ID3v2.3 header
        var tag = Data()
        tag.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        tag.append(contentsOf: [0x03, 0x00])         // Version 2.3.0
        tag.append(0x00)                              // Flags

        // Size as syncsafe integer (frames only, excluding 10-byte header)
        let size = frames.count
        tag.append(UInt8((size >> 21) & 0x7F))
        tag.append(UInt8((size >> 14) & 0x7F))
        tag.append(UInt8((size >> 7) & 0x7F))
        tag.append(UInt8(size & 0x7F))

        tag.append(frames)

        // Strip existing ID3v2 tag if present
        let audio = stripID3v2(from: audioData)
        var result = tag
        result.append(audio)
        return result
    }

    private static func textFrame(id: String, text: String) -> Data {
        // Encoding byte (0x03 = UTF-8) + text bytes
        var payload = Data()
        payload.append(0x03) // UTF-8
        payload.append(contentsOf: Array(text.utf8))

        var frame = Data()
        frame.append(contentsOf: Array(id.utf8))
        frame.append(uint32BE(UInt32(payload.count)))
        frame.append(contentsOf: [0x00, 0x00]) // Flags
        frame.append(payload)
        return frame
    }

    private static func pictureFrame(imageData: Data, mimeType: String) -> Data {
        var payload = Data()
        payload.append(0x00) // Encoding: ISO-8859-1 for mime/description
        payload.append(contentsOf: Array(mimeType.utf8))
        payload.append(0x00) // Null terminator for mime type
        payload.append(0x03) // Picture type: Cover (front)
        payload.append(0x00) // Null terminator for description
        payload.append(imageData)

        var frame = Data()
        frame.append(contentsOf: Array("APIC".utf8))
        frame.append(uint32BE(UInt32(payload.count)))
        frame.append(contentsOf: [0x00, 0x00]) // Flags
        frame.append(payload)
        return frame
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        var data = Data(count: 4)
        data[0] = UInt8((value >> 24) & 0xFF)
        data[1] = UInt8((value >> 16) & 0xFF)
        data[2] = UInt8((value >> 8) & 0xFF)
        data[3] = UInt8(value & 0xFF)
        return data
    }

    private static func stripID3v2(from data: Data) -> Data {
        guard data.count >= 10 else { return data }
        let bytes = Array(data.prefix(10))
        // Check for "ID3" header
        guard bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else {
            return data
        }
        // Syncsafe size: each of the 4 size bytes must have its high bit clear.
        // A malformed tag with the high bit set is not a valid ID3v2 size and
        // would otherwise produce an inflated `totalTagSize`.
        guard bytes[6] & 0x80 == 0,
              bytes[7] & 0x80 == 0,
              bytes[8] & 0x80 == 0,
              bytes[9] & 0x80 == 0 else {
            return data
        }
        // Read syncsafe size
        let size = (Int(bytes[6]) << 21) | (Int(bytes[7]) << 14) | (Int(bytes[8]) << 7) | Int(bytes[9])
        let totalTagSize = size + 10
        guard totalTagSize <= data.count else { return data }
        return data.dropFirst(totalTagSize).asData()
    }
}

private extension Data.SubSequence {
    func asData() -> Data {
        return Data(self)
    }
}
