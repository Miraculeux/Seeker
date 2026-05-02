import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreLocation

/// Read/write a small, curated set of writable EXIF/TIFF/GPS/IPTC fields.
///
/// Camera hardware fields (Make/Model/Serial, ExposureTime, FNumber, ISO,
/// FocalLength, MakerNote, etc.) are intentionally excluded from the
/// writable surface — modifying them produces misleading metadata and can
/// break vendor tools that validate MakerNote.
struct EditableMetadata {
    // TIFF / common
    var imageDescription: String = ""
    var artist: String = ""
    var copyright: String = ""
    var software: String = ""

    // EXIF
    var userComment: String = ""
    var dateTimeOriginal: Date?

    // IPTC
    var keywords: [String] = []
    var rating: Int = 0   // 0...5 (XMP/IPTC rating, mirrored to TIFF Rating)

    // GPS — `nil` means "no location" (will be removed on write).
    var location: CLLocationCoordinate2D?
    var altitude: Double?

    static let empty = EditableMetadata()
}

extension EditableMetadata: Equatable {
    static func == (lhs: EditableMetadata, rhs: EditableMetadata) -> Bool {
        lhs.imageDescription == rhs.imageDescription
            && lhs.artist == rhs.artist
            && lhs.copyright == rhs.copyright
            && lhs.software == rhs.software
            && lhs.userComment == rhs.userComment
            && lhs.dateTimeOriginal == rhs.dateTimeOriginal
            && lhs.keywords == rhs.keywords
            && lhs.rating == rhs.rating
            && lhs.location?.latitude == rhs.location?.latitude
            && lhs.location?.longitude == rhs.location?.longitude
            && lhs.altitude == rhs.altitude
    }
}

/// Read-only camera context surfaced in the editor for reference.
struct ReadOnlyCameraInfo {
    var make: String?
    var model: String?
    var lensModel: String?
    var bodySerialNumber: String?
    var exposureTime: String?
    var fNumber: String?
    var iso: String?
    var focalLength: String?
    var pixelDimensions: String?
}

enum ExifEditorError: LocalizedError {
    case unsupportedType
    case sourceUnreadable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedType: return "This image type is not supported for metadata editing."
        case .sourceUnreadable: return "The image could not be opened."
        case .writeFailed: return "Failed to write metadata to the image."
        }
    }
}

enum ExifEditor {
    // MARK: - Read

    /// Loads the editable subset of metadata from `url`. Returns an empty
    /// struct if the file has no readable metadata.
    static func read(from url: URL) -> EditableMetadata {
        var meta = EditableMetadata()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return meta }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let gps  = props[kCGImagePropertyGPSDictionary]  as? [CFString: Any] ?? [:]

        meta.imageDescription = (tiff[kCGImagePropertyTIFFImageDescription] as? String)
            ?? (iptc[kCGImagePropertyIPTCCaptionAbstract] as? String)
            ?? ""
        meta.artist = (tiff[kCGImagePropertyTIFFArtist] as? String)
            ?? (iptc[kCGImagePropertyIPTCByline] as? String)
            ?? ""
        meta.copyright = (tiff[kCGImagePropertyTIFFCopyright] as? String)
            ?? (iptc[kCGImagePropertyIPTCCopyrightNotice] as? String)
            ?? ""
        meta.software = tiff[kCGImagePropertyTIFFSoftware] as? String ?? ""
        meta.userComment = exif[kCGImagePropertyExifUserComment] as? String ?? ""

        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            meta.dateTimeOriginal = exifDateFormatter.date(from: s)
        }

        if let kw = iptc[kCGImagePropertyIPTCKeywords] as? [String] {
            meta.keywords = kw
        }
        if let r = iptc[kCGImagePropertyIPTCStarRating] as? Int {
            meta.rating = max(0, min(5, r))
        }

        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
            let signedLat = latRef.uppercased() == "S" ? -lat : lat
            let signedLon = lonRef.uppercased() == "W" ? -lon : lon
            meta.location = CLLocationCoordinate2D(latitude: signedLat, longitude: signedLon)
        }
        if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
            let ref = gps[kCGImagePropertyGPSAltitudeRef] as? Int ?? 0
            meta.altitude = ref == 1 ? -alt : alt
        }

        return meta
    }

    /// Reads camera/exposure context for display next to the editor.
    static func readCameraInfo(from url: URL) -> ReadOnlyCameraInfo {
        var info = ReadOnlyCameraInfo()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return info }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]

        info.make = tiff[kCGImagePropertyTIFFMake] as? String
        info.model = tiff[kCGImagePropertyTIFFModel] as? String
        info.lensModel = exif[kCGImagePropertyExifLensModel] as? String
        info.bodySerialNumber = exif[kCGImagePropertyExifBodySerialNumber] as? String

        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            info.exposureTime = t >= 1
                ? String(format: "%.1f s", t)
                : "1/\(Int((1.0 / t).rounded())) s"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double {
            info.fNumber = String(format: "f/%.1f", f)
        }
        if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
           let iso = isoArr.first {
            info.iso = "ISO \(iso)"
        }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
            info.focalLength = "\(Int(fl.rounded())) mm"
        }
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            info.pixelDimensions = "\(w) × \(h)"
        }
        return info
    }

    // MARK: - Write

    /// Writes `meta` back to `source`. When `destination` differs from
    /// `source`, the original is left untouched ("Save a Copy" semantics).
    static func write(
        _ meta: EditableMetadata,
        from source: URL,
        to destination: URL
    ) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ExifEditorError.sourceUnreadable
        }
        guard let uti = CGImageSourceGetType(src) else {
            throw ExifEditorError.unsupportedType
        }

        // Build the merged property tree.
        let baseProps = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var tiff = baseProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var exif = baseProps[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var iptc = baseProps[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        // TIFF text fields — empty string clears the tag.
        setOrRemove(&tiff, kCGImagePropertyTIFFImageDescription, meta.imageDescription)
        setOrRemove(&tiff, kCGImagePropertyTIFFArtist, meta.artist)
        setOrRemove(&tiff, kCGImagePropertyTIFFCopyright, meta.copyright)
        setOrRemove(&tiff, kCGImagePropertyTIFFSoftware, meta.software)

        // Mirror to IPTC for broader interop.
        setOrRemove(&iptc, kCGImagePropertyIPTCCaptionAbstract, meta.imageDescription)
        setOrRemove(&iptc, kCGImagePropertyIPTCByline, meta.artist)
        setOrRemove(&iptc, kCGImagePropertyIPTCCopyrightNotice, meta.copyright)

        // EXIF
        setOrRemove(&exif, kCGImagePropertyExifUserComment, meta.userComment)
        if let date = meta.dateTimeOriginal {
            let s = exifDateFormatter.string(from: date)
            exif[kCGImagePropertyExifDateTimeOriginal] = s
            exif[kCGImagePropertyExifDateTimeDigitized] = s
            tiff[kCGImagePropertyTIFFDateTime] = s
        } else {
            exif.removeValue(forKey: kCGImagePropertyExifDateTimeOriginal)
            exif.removeValue(forKey: kCGImagePropertyExifDateTimeDigitized)
            tiff.removeValue(forKey: kCGImagePropertyTIFFDateTime)
        }

        // IPTC keywords / rating
        if meta.keywords.isEmpty {
            iptc.removeValue(forKey: kCGImagePropertyIPTCKeywords)
        } else {
            iptc[kCGImagePropertyIPTCKeywords] = meta.keywords
        }
        if meta.rating > 0 {
            iptc[kCGImagePropertyIPTCStarRating] = meta.rating
        } else {
            iptc.removeValue(forKey: kCGImagePropertyIPTCStarRating)
        }

        // Compose final dictionary
        var props = baseProps
        props[kCGImagePropertyTIFFDictionary] = tiff
        props[kCGImagePropertyExifDictionary] = exif
        props[kCGImagePropertyIPTCDictionary] = iptc
        props[kCGImagePropertyGPSDictionary] = makeGPSDict(meta: meta)
        // If GPS was cleared, drop the dictionary entirely.
        if props[kCGImagePropertyGPSDictionary] as? [CFString: Any] == nil {
            props.removeValue(forKey: kCGImagePropertyGPSDictionary)
        }

        try writeImage(src: src, uti: uti, properties: props, to: destination)
    }

    /// Convenience: removes GPS + body serial number + user comment.
    /// Keeps everything else (camera model, exposure, etc.) intact.
    static func stripPrivacyFields(at url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ExifEditorError.sourceUnreadable
        }
        guard let uti = CGImageSourceGetType(src) else {
            throw ExifEditorError.unsupportedType
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props.removeValue(forKey: kCGImagePropertyGPSDictionary)

        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifBodySerialNumber)
            exif.removeValue(forKey: kCGImagePropertyExifUserComment)
            props[kCGImagePropertyExifDictionary] = exif
        }
        try writeImage(src: src, uti: uti, properties: props, to: url)
    }

    // MARK: - Internals

    private static func writeImage(
        src: CGImageSource,
        uti: CFString,
        properties: [CFString: Any],
        to destination: URL
    ) throws {
        // Write to a sibling temp file then atomically replace, so an error
        // mid-write never leaves the user with a truncated original.
        let tmpURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).seeker-tmp-\(UUID().uuidString)")

        guard let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL, uti, 1, nil) else {
            throw ExifEditorError.writeFailed
        }
        CGImageDestinationAddImageFromSource(dest, src, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw ExifEditorError.writeFailed
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw ExifEditorError.writeFailed
        }
    }

    private static func setOrRemove(
        _ dict: inout [CFString: Any],
        _ key: CFString,
        _ value: String
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: key)
        } else {
            dict[key] = trimmed
        }
    }

    private static func makeGPSDict(meta: EditableMetadata) -> [CFString: Any]? {
        guard let loc = meta.location else { return nil }
        var gps: [CFString: Any] = [:]
        gps[kCGImagePropertyGPSLatitude] = abs(loc.latitude)
        gps[kCGImagePropertyGPSLatitudeRef] = loc.latitude >= 0 ? "N" : "S"
        gps[kCGImagePropertyGPSLongitude] = abs(loc.longitude)
        gps[kCGImagePropertyGPSLongitudeRef] = loc.longitude >= 0 ? "E" : "W"
        if let alt = meta.altitude {
            gps[kCGImagePropertyGPSAltitude] = abs(alt)
            gps[kCGImagePropertyGPSAltitudeRef] = alt < 0 ? 1 : 0
        }
        let now = Date()
        gps[kCGImagePropertyGPSDateStamp] = gpsDateFormatter.string(from: now)
        gps[kCGImagePropertyGPSTimeStamp] = gpsTimeFormatter.string(from: now)
        return gps
    }

    // EXIF dates use this exact format (no timezone).
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static let gpsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd"
        return f
    }()

    private static let gpsTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
