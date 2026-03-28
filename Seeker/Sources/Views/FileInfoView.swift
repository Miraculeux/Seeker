import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct FileInfoView: View {
    @Environment(AppState.self) var appState

    private var selectedFile: FileItem? {
        appState.activeExplorer.selectedFile
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Info")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider()

            if let file = selectedFile {
                fileInfoContent(file)
            } else {
                noSelection
            }
        }
        .frame(width: 220)
        .background(.background)
    }

    // MARK: - No Selection

    private var noSelection: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No Selection")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File Info Content

    private func fileInfoContent(_ file: FileItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Icon + Name
                VStack(spacing: 8) {
                    Image(nsImage: file.nsIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)

                    Text(file.name)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    Text(file.typeDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 16)

                Divider()
                    .padding(.horizontal, 12)

                // Details
                VStack(spacing: 10) {
                    if !file.isDirectory {
                        infoRow("Size", file.formattedSize)
                        infoRow("Bytes", formattedBytes(file.fileSize))
                    } else {
                        infoRow("Kind", "Folder")
                    }

                    if let created = file.creationDate {
                        infoRow("Created", formatFullDate(created))
                    }

                    if let modified = file.modificationDate {
                        infoRow("Modified", formatFullDate(modified))
                    }

                    infoRow("Extension", file.url.pathExtension.isEmpty ? "—" : file.url.pathExtension.uppercased())
                }
                .padding(.horizontal, 12)

                Divider()
                    .padding(.horizontal, 12)

                // Path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Path")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(file.url.path)
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.7))
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)

                Divider()
                    .padding(.horizontal, 12)

                // Permissions
                permissionsSection(file)

                // EXIF for images
                if let exifInfo = imageMetadata(for: file) {
                    Divider()
                        .padding(.horizontal, 12)

                    exifSection(exifInfo)
                }

                Spacer(minLength: 16)
            }
        }
    }

    // MARK: - Info Row

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .trailing)
            Text(value)
                .font(.system(size: 10))
                .foregroundColor(.primary.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Permissions

    private func permissionsSection(_ file: FileItem) -> some View {
        let fm = FileManager.default
        let path = file.url.path
        let readable = fm.isReadableFile(atPath: path)
        let writable = fm.isWritableFile(atPath: path)
        let executable = fm.isExecutableFile(atPath: path)

        return VStack(spacing: 6) {
            HStack {
                Text("Permissions")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                permBadge("R", active: readable)
                permBadge("W", active: writable)
                permBadge("X", active: executable)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
    }

    private func permBadge(_ letter: String, active: Bool) -> some View {
        Text(letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(active ? .white : .secondary.opacity(0.5))
            .frame(width: 22, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06))
            )
    }

    // MARK: - Helpers

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)") + " bytes"
    }

    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Image EXIF

    private struct ImageMetadata {
        var dimensions: String?
        var colorSpace: String?
        var dpi: String?
        var bitDepth: String?
        // EXIF
        var cameraMake: String?
        var cameraModel: String?
        var lens: String?
        var focalLength: String?
        var aperture: String?
        var shutterSpeed: String?
        var iso: String?
        var dateOriginal: String?
        var flash: String?
        var whiteBalance: String?
        // GPS
        var latitude: String?
        var longitude: String?
        var altitude: String?
    }

    private func imageMetadata(for file: FileItem) -> ImageMetadata? {
        guard !file.isDirectory else { return nil }
        let ext = file.url.pathExtension.lowercased()
        let imageExts = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "gif", "bmp", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2"]
        guard imageExts.contains(ext) else { return nil }

        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        var meta = ImageMetadata()

        // Dimensions
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            meta.dimensions = "\(w) × \(h)"
        }

        // Color space
        if let cs = props[kCGImagePropertyColorModel] as? String {
            meta.colorSpace = cs
        }

        // DPI
        if let dpiX = props[kCGImagePropertyDPIWidth] as? Double {
            meta.dpi = "\(Int(dpiX))"
        }

        // Bit depth
        if let depth = props[kCGImagePropertyDepth] as? Int {
            meta.bitDepth = "\(depth) bit"
        }

        // EXIF dictionary
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let make = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                meta.cameraMake = make[kCGImagePropertyTIFFMake] as? String
                meta.cameraModel = make[kCGImagePropertyTIFFModel] as? String
            }

            if let lens = exif[kCGImagePropertyExifLensModel] as? String {
                meta.lens = lens
            }

            if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
                meta.focalLength = "\(Int(fl)) mm"
            }

            if let ap = exif[kCGImagePropertyExifFNumber] as? Double {
                meta.aperture = String(format: "f/%.1f", ap)
            }

            if let ss = exif[kCGImagePropertyExifExposureTime] as? Double {
                if ss >= 1 {
                    meta.shutterSpeed = String(format: "%.1f s", ss)
                } else {
                    meta.shutterSpeed = "1/\(Int(1.0 / ss)) s"
                }
            }

            if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArr.first {
                meta.iso = "ISO \(iso)"
            }

            if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                meta.dateOriginal = date
            }

            if let flash = exif[kCGImagePropertyExifFlash] as? Int {
                meta.flash = (flash & 1) == 1 ? "Fired" : "Off"
            }

            if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int {
                meta.whiteBalance = wb == 0 ? "Auto" : "Manual"
            }
        } else {
            // Try TIFF dict for make/model even without EXIF
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                meta.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
                meta.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            }
        }

        // GPS
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String {
                meta.latitude = String(format: "%.6f° %@", lat, latRef)
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
               let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                meta.longitude = String(format: "%.6f° %@", lon, lonRef)
            }
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
                meta.altitude = String(format: "%.1f m", alt)
            }
        }

        return meta
    }

    private func exifSection(_ meta: ImageMetadata) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Image")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }

            if let d = meta.dimensions { infoRow("Size", d) }
            if let cs = meta.colorSpace { infoRow("Color", cs) }
            if let dpi = meta.dpi { infoRow("DPI", dpi) }
            if let bd = meta.bitDepth { infoRow("Depth", bd) }

            if meta.cameraMake != nil || meta.cameraModel != nil || meta.aperture != nil {
                Divider()

                HStack {
                    Text("Camera")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if let make = meta.cameraMake { infoRow("Make", make) }
                if let model = meta.cameraModel { infoRow("Model", model) }
                if let lens = meta.lens { infoRow("Lens", lens) }
                if let fl = meta.focalLength { infoRow("Focal", fl) }
                if let ap = meta.aperture { infoRow("Aperture", ap) }
                if let ss = meta.shutterSpeed { infoRow("Shutter", ss) }
                if let iso = meta.iso { infoRow("ISO", iso) }
                if let flash = meta.flash { infoRow("Flash", flash) }
                if let wb = meta.whiteBalance { infoRow("WB", wb) }
                if let date = meta.dateOriginal { infoRow("Taken", date) }
            }

            if meta.latitude != nil || meta.longitude != nil {
                Divider()

                HStack {
                    Text("Location")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if let lat = meta.latitude { infoRow("Lat", lat) }
                if let lon = meta.longitude { infoRow("Lon", lon) }
                if let alt = meta.altitude { infoRow("Alt", alt) }
            }
        }
        .padding(.horizontal, 12)
    }
}
