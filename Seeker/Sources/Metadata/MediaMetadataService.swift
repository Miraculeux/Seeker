import Foundation
import AppKit

/// Routes media metadata read/write to the right dependency-free parser.
/// Covers audio + video containers; image EXIF stays in `ExifEditor`.
enum MediaMetadataService {

    /// File extensions for which we support full read+write of tag metadata.
    static let writableExtensions: Set<String> = [
        "flac",
        "mp3",
        "m4a", "m4b", "mp4", "m4v", "mov", "alac",
        "aiff", "aif", "aifc",
        "mka", "mkv", "webm",
        "avi",
        "dsf", "dff",
    ]

    static func isSupported(_ url: URL) -> Bool {
        writableExtensions.contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL) throws -> MediaMetadata {
        switch url.pathExtension.lowercased() {
        case "flac":
            return mediaMetadata(fromFlac: try FlacFile.read(url))
        case "mp3":
            return mediaMetadata(fromID3Decoded: try ID3v2File.read(url).decoded())
        case "m4a", "m4b", "mp4", "m4v", "mov", "alac":
            let decoded = try MP4File.read(url).decoded()
            var md = MediaMetadata(
                vendor: nil,
                tags: decoded.entries.map { .init(key: $0.key, value: $0.value) }
            )
            if let c = decoded.cover {
                md.coverArt = c.data
                md.coverMimeType = c.mime
            }
            return md
        case "aiff", "aif", "aifc":
            return mediaMetadata(fromID3Decoded: try AIFFFile.read(url).decoded())
        case "mka", "mkv", "webm":
            let file = try MatroskaFile.read(url)
            var md = MediaMetadata(
                vendor: nil,
                tags: file.entries.map { .init(key: $0.key, value: $0.value) }
            )
            if let cover = file.cover {
                md.coverArt = cover.data
                md.coverMimeType = cover.mime
            }
            return md
        case "avi":
            return MediaMetadata(
                vendor: nil,
                tags: try AVIFile.read(url).entries
                    .map { .init(key: $0.key, value: $0.value) }
            )
        case "dsf":
            return mediaMetadata(fromID3Decoded: try DSFFile.read(url).decoded())
        case "dff":
            return mediaMetadata(fromID3Decoded: try DFFFile.read(url).decoded())
        default:
            throw NSError(domain: "MediaMetadataService", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Unsupported format: .\(url.pathExtension)"])
        }
    }

    static func write(_ md: MediaMetadata, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "flac": try writeFlac(md, to: url)
        case "mp3":  try writeMP3(md, to: url)
        case "m4a", "m4b", "mp4", "m4v", "mov", "alac":
            try writeMP4(md, to: url)
        case "aiff", "aif", "aifc":
            try writeAIFF(md, to: url)
        case "mka", "mkv", "webm":
            try writeMatroska(md, to: url)
        case "avi":
            let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
            try AVIFile.write(url: url, entries: entries)
        case "dsf": try writeDSF(md, to: url)
        case "dff": try writeDFF(md, to: url)
        default:
            throw NSError(domain: "MediaMetadataService", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Writing tags for .\(url.pathExtension) is not supported."])
        }
    }

    // MARK: - Format-specific writers

    private static func writeFlac(_ md: MediaMetadata, to url: URL) throws {
        var file = try FlacFile.read(url)
        let vc = VorbisComment(
            vendor: md.vendor ?? "Seeker",
            entries: md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        )
        file.setVorbisComment(vc)
        if let data = md.coverArt {
            let mime = md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg"
            let (w, h) = imageDimensions(data) ?? (0, 0)
            file.setFrontCover(FlacPicture(
                pictureType: 3, mimeType: mime, description: "",
                width: UInt32(w), height: UInt32(h),
                depth: 24, colors: 0, data: data
            ))
        }
        try file.write()
    }

    private static func writeMP3(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        try ID3v2File.write(url: url, entries: entries, cover: cover(from: md))
    }

    private static func writeMP4(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        let c: MP4File.Cover?
        if let data = md.coverArt {
            c = MP4File.Cover(
                data: data,
                mime: md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg")
        } else {
            c = nil
        }
        try MP4File.write(url: url, entries: entries, cover: c)
    }

    private static func writeAIFF(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        try AIFFFile.write(url: url, entries: entries, cover: cover(from: md))
    }

    private static func writeMatroska(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        try MatroskaFile.write(url: url, entries: entries, cover: cover(from: md))
    }

    private static func writeDSF(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        try DSFFile.write(url: url, entries: entries, cover: cover(from: md))
    }

    private static func writeDFF(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        try DFFFile.write(url: url, entries: entries, cover: cover(from: md))
    }

    // MARK: - Helpers

    private static func mediaMetadata(fromFlac file: FlacFile) -> MediaMetadata {
        let vc = file.vorbisComment
        var md = MediaMetadata(
            vendor: vc.vendor,
            tags: vc.entries.map { .init(key: $0.key, value: $0.value) }
        )
        if let pic = file.firstPicture {
            md.coverArt = pic.data
            md.coverMimeType = pic.mimeType
        }
        return md
    }

    private static func mediaMetadata(
        fromID3Decoded decoded: (entries: [(key: String, value: String)],
                                 cover: (data: Data, mime: String)?)
    ) -> MediaMetadata {
        var md = MediaMetadata(
            vendor: nil,
            tags: decoded.entries.map { .init(key: $0.key, value: $0.value) }
        )
        if let cover = decoded.cover {
            md.coverArt = cover.data
            md.coverMimeType = cover.mime
        }
        return md
    }

    private static func cover(from md: MediaMetadata) -> (Data, String)? {
        guard let data = md.coverArt else { return nil }
        return (data, md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg")
    }

    private static func mimeForImageData(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(4))
        if b[0] == 0xFF && b[1] == 0xD8 { return "image/jpeg" }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return "image/png" }
        return nil
    }

    private static func imageDimensions(_ data: Data) -> (Int, Int)? {
        guard let img = NSImage(data: data),
              let rep = img.representations.first
        else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}
