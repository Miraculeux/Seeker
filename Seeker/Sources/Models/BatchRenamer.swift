import Foundation
import Observation
import ImageIO

/// Computes and applies batch renames for a set of files. Three modes:
///
/// 1. **Find & Replace** — substitute a substring (optionally
///    case-insensitive, optionally as a regular expression).
/// 2. **Sequence** — `prefix` + zero-padded running number + `suffix`.
/// 3. **EXIF date** — `date` + optional separator + zero-padded number,
///    where the date comes from the image's EXIF *DateTimeOriginal*
///    (falling back to the file's creation date) and is formatted with a
///    user-supplied pattern.
///
/// The file extension is always preserved for the Sequence and EXIF
/// modes; Find & Replace operates on the whole file name so it can touch
/// the extension if the user really wants to.
@MainActor @Observable
final class BatchRenamer {
    enum Mode: String, CaseIterable, Identifiable {
        case findReplace
        case sequence
        case exifDate
        var id: String { rawValue }
        var title: String {
            switch self {
            case .findReplace: return "Find & Replace"
            case .sequence: return "Numbered"
            case .exifDate: return "By Date (EXIF)"
            }
        }
    }

    /// One row of the live preview: the current name and what it would
    /// become. `error` is set when a name can't be produced or collides.
    struct Preview: Identifiable {
        let id: URL
        let oldName: String
        let newName: String
        var error: String?
        var changed: Bool { error == nil && oldName != newName }
    }

    let urls: [URL]

    var mode: Mode = .findReplace

    // MARK: Find & Replace
    var find = ""
    var replacement = ""
    /// Default: case-insensitive ("默认不区分").
    var ignoreCase = true
    /// Default: literal substring ("默认为常规字符匹配").
    var useRegex = false

    // MARK: Sequence
    var prefix = ""
    var suffix = ""
    var startNumber = 1

    // MARK: EXIF date
    /// User-facing date pattern. Accepts both DateFormatter syntax and
    /// common uppercase tokens (YYYY, YY, DD) which are normalised below.
    var dateFormat = "yyyy-MM-dd"
    var useSeparator = true
    var separator = "-"
    var dateStartNumber = 1

    /// Cached source dates (EXIF or file creation) so re-formatting on
    /// every keystroke doesn't re-read every file.
    private var sourceDates: [URL: Date] = [:]
    var isLoadingDates = false

    init(urls: [URL]) {
        self.urls = urls
    }

    // MARK: - Date loading

    /// Reads EXIF/creation dates for all files off the main thread, then
    /// caches them. Cheap to call repeatedly — it only loads once.
    func loadDatesIfNeeded() async {
        guard sourceDates.isEmpty, !urls.isEmpty else { return }
        isLoadingDates = true
        let urls = self.urls
        let dates = await Task.detached(priority: .userInitiated) { () -> [URL: Date] in
            var out: [URL: Date] = [:]
            for url in urls {
                if let d = Self.exifDate(for: url) ?? Self.creationDate(for: url) {
                    out[url] = d
                }
            }
            return out
        }.value
        sourceDates = dates
        isLoadingDates = false
    }

    nonisolated static func exifDate(for url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    nonisolated static func creationDate(for url: URL) -> Date? {
        let v = try? url.resourceValues(forKeys: [.creationDateKey])
        return v?.creationDate
    }

    // MARK: - Preview

    /// Produces the preview rows for the current settings, including
    /// collision detection (duplicate targets, or a target that already
    /// exists on disk and isn't one of the renamed sources).
    func previews() -> [Preview] {
        var rows: [Preview] = []
        rows.reserveCapacity(urls.count)

        // First pass: compute raw new names.
        var newNames: [String] = []
        switch mode {
        case .findReplace:
            for url in urls {
                newNames.append(findReplaceName(for: url))
            }
        case .sequence:
            let width = numberWidth(start: startNumber, count: urls.count)
            for (i, url) in urls.enumerated() {
                newNames.append(sequenceName(for: url, index: i, width: width))
            }
        case .exifDate:
            let width = numberWidth(start: dateStartNumber, count: urls.count)
            for (i, url) in urls.enumerated() {
                newNames.append(exifName(for: url, index: i, width: width))
            }
        }

        // Second pass: collision detection.
        let sourcePaths = Set(urls.map { $0.standardizedFileURL.path })
        // Count target names per parent directory.
        var targetCounts: [String: Int] = [:]
        for (i, url) in urls.enumerated() {
            let target = url.deletingLastPathComponent()
                .appendingPathComponent(newNames[i]).standardizedFileURL.path
            targetCounts[target, default: 0] += 1
        }

        for (i, url) in urls.enumerated() {
            let oldName = url.lastPathComponent
            let newName = newNames[i]
            var error: String?
            if newName.isEmpty {
                error = "Empty name"
            } else if newName.contains("/") || newName == "." || newName == ".." || newName.contains("\0") {
                error = "Invalid name"
            } else {
                let targetURL = url.deletingLastPathComponent().appendingPathComponent(newName)
                let targetPath = targetURL.standardizedFileURL.path
                if targetCounts[targetPath, default: 0] > 1 {
                    error = "Duplicate target"
                } else if FileManager.default.fileExists(atPath: targetPath),
                          !sourcePaths.contains(targetPath) {
                    error = "Already exists"
                }
            }
            rows.append(Preview(id: url, oldName: oldName, newName: newName, error: error))
        }
        return rows
    }

    /// True when at least one file would be renamed and none are errored.
    func canApply(_ previews: [Preview]) -> Bool {
        previews.contains(where: { $0.changed }) && !previews.contains(where: { $0.error != nil })
    }

    // MARK: - Name builders

    private func findReplaceName(for url: URL) -> String {
        let name = url.lastPathComponent
        guard !find.isEmpty else { return name }
        if useRegex {
            let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: find, options: options) else {
                return name
            }
            let range = NSRange(name.startIndex..., in: name)
            return re.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: replacement)
        } else {
            let options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
            return name.replacingOccurrences(of: find, with: replacement, options: options)
        }
    }

    private func sequenceName(for url: URL, index: Int, width: Int) -> String {
        let ext = url.pathExtension
        let number = String(format: "%0\(width)d", startNumber + index)
        let base = "\(prefix)\(number)\(suffix)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private func exifName(for url: URL, index: Int, width: Int) -> String {
        let ext = url.pathExtension
        let number = String(format: "%0\(width)d", dateStartNumber + index)
        let datePart: String
        if let date = sourceDates[url] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = Self.normalizedDateFormat(dateFormat)
            datePart = f.string(from: date)
        } else {
            datePart = "nodate"
        }
        let sep = useSeparator ? separator : ""
        let base = "\(datePart)\(sep)\(number)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private func numberWidth(start: Int, count: Int) -> Int {
        let last = start + max(count - 1, 0)
        return max(String(last).count, 1)
    }

    /// Translates common uppercase date tokens to `DateFormatter` syntax
    /// so users can type `YYYY-MM-DD` or `YYMMDD` as in the spec.
    nonisolated static func normalizedDateFormat(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "YYYY", with: "yyyy")
        r = r.replacingOccurrences(of: "YY", with: "yy")
        r = r.replacingOccurrences(of: "DD", with: "dd")
        return r
    }

    // MARK: - Apply

    /// Performs the renames off the main thread using a two-pass staging
    /// strategy (source → temp → final) so cyclic renames (a↔b) and other
    /// in-set collisions are handled safely. Returns the `(old, new)`
    /// pairs that succeeded plus any error messages.
    func apply() async -> (renamed: [(from: URL, to: URL)], errors: [String]) {
        let rows = previews().filter { $0.changed }
        guard !rows.isEmpty else { return ([], []) }
        let plan = rows.map { (from: $0.id, toName: $0.newName) }

        return await Task.detached(priority: .userInitiated) { () -> (renamed: [(from: URL, to: URL)], errors: [String]) in
            let fm = FileManager.default
            var renamed: [(from: URL, to: URL)] = []
            var errors: [String] = []

            // Pass 1: move every source to a unique temp name in-place.
            var staged: [(temp: URL, final: URL)] = []
            for (from, toName) in plan {
                let dir = from.deletingLastPathComponent()
                let final = dir.appendingPathComponent(toName)
                let temp = dir.appendingPathComponent(".seeker-rename-\(UUID().uuidString)")
                do {
                    try fm.moveItem(at: from, to: temp)
                    staged.append((temp: temp, final: final))
                    renamed.append((from: from, to: final))
                } catch {
                    errors.append("\(from.lastPathComponent): \(error.localizedDescription)")
                }
            }

            // Pass 2: move temps to their final names.
            for (temp, final) in staged {
                do {
                    try fm.moveItem(at: temp, to: final)
                } catch {
                    errors.append("\(final.lastPathComponent): \(error.localizedDescription)")
                    // Best-effort restore isn't attempted; leave the temp
                    // so nothing is lost.
                }
            }
            return (renamed, errors)
        }.value
    }
}
