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
/// The file extension is always preserved in every mode: Sequence and
/// EXIF build a fresh name and re-append the extension, and Find & Replace
/// only operates on the name portion without the extension so the suffix
/// is never matched or altered.
@MainActor @Observable
final class BatchRenamer {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
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
    struct Preview: Identifiable, Sendable {
        let id: URL
        let oldName: String
        let newName: String
        var error: String?
        var changed: Bool { error == nil && oldName != newName }
    }

    var urls: [URL]

    var mode: Mode = .findReplace
    var extensionFilter = ""

    var filteredURLs: [URL] {
        settings.filteredURLs
    }

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
    private var checkedDates: Set<URL> = []
    private(set) var isLoadingDates = false
    private(set) var isPreviewLoading = true
    private(set) var previewRows: [Preview] = []

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var dateTask: Task<DateResults, Never>?
    @ObservationIgnored private var dateScope: DateScope?
    @ObservationIgnored private var dateGeneration = 0
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var acceptedSettings: Settings?
    @ObservationIgnored private var isApplying = false

    /// Only value types cross into workers; they never read observable state.
    private struct Settings: Equatable, Sendable {
        let urls: [URL]
        let extensionFilter: String
        let mode: Mode
        let find: String
        let replacement: String
        let ignoreCase: Bool
        let useRegex: Bool
        let prefix: String
        let suffix: String
        let startNumber: Int
        let dateFormat: String
        let useSeparator: Bool
        let separator: String
        let dateStartNumber: Int

        var filteredURLs: [URL] {
            let extensions = Set(extensionFilter
                .components(separatedBy: CharacterSet(charactersIn: ",; "))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 }
                .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                .map { $0.lowercased() })
            guard !extensions.isEmpty else { return urls }
            return urls.filter { extensions.contains($0.pathExtension.lowercased()) }
        }
    }

    private struct DateScope: Equatable {
        let urls: [URL]
        let extensionFilter: String
    }

    private struct DateResults: Sendable {
        var dates: [URL: Date] = [:]
        var checked: Set<URL> = []
    }

    private var settings: Settings {
        Settings(
            urls: urls, extensionFilter: extensionFilter, mode: mode,
            find: find, replacement: replacement, ignoreCase: ignoreCase, useRegex: useRegex,
            prefix: prefix, suffix: suffix, startNumber: startNumber,
            dateFormat: dateFormat, useSeparator: useSeparator, separator: separator,
            dateStartNumber: dateStartNumber
        )
    }

    init(urls: [URL]) {
        self.urls = urls
    }

    // MARK: - Date loading

    /// Formatting edits share one metadata worker, including failed lookups.
    /// Scope/mode changes and dismissal cancel that worker explicitly.
    private func loadDatesIfNeeded(for snapshot: Settings) async {
        if dateTask == nil {
            let checked = checkedDates
            dateScope = DateScope(urls: snapshot.urls, extensionFilter: snapshot.extensionFilter)
            isLoadingDates = true
            dateTask = Task.detached(priority: .userInitiated) {
                var result = DateResults()
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                for url in snapshot.filteredURLs {
                    guard !Task.isCancelled else { break }
                    guard !checked.contains(url), !result.checked.contains(url) else { continue }
                    let date = Self.exifDate(for: url, formatter: formatter)
                    guard !Task.isCancelled else { break }
                    if let date = date ?? Self.creationDate(for: url) {
                        result.dates[url] = date
                    }
                    result.checked.insert(url)
                }
                return result
            }
        }
        guard let task = dateTask else { return }
        let generation = dateGeneration
        // A cancelled preview waiter must not cancel metadata shared by its successor.
        // Only scope/mode changes or dismissal cancel the owned date task.
        let result = await task.value
        guard generation == dateGeneration else { return }
        sourceDates.merge(result.dates) { _, new in new }
        checkedDates.formUnion(result.checked)
        // Other waiters may still be resuming from this same task.
        dateGeneration += 1
        dateTask = nil
        dateScope = nil
        isLoadingDates = false
    }

    private func cancelDateLoading() {
        dateGeneration += 1
        dateTask?.cancel()
        dateTask = nil
        dateScope = nil
        isLoadingDates = false
    }

    private nonisolated static func exifDate(for url: URL, formatter: DateFormatter) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return formatter.date(from: s)
    }

    nonisolated static func creationDate(for url: URL) -> Date? {
        let v = try? url.resourceValues(forKeys: [.creationDateKey])
        return v?.creationDate
    }

    // MARK: - Preview

    /// Invalidates synchronously, then debounces the expensive off-main pass.
    func requestPreview() {
        let snapshot = settings
        // Ending text editing can commit an unchanged value when Apply disables the form.
        // Keep that accepted preview valid, including during apply-time revalidation.
        guard snapshot != acceptedSettings else { return }
        previewGeneration += 1
        let generation = previewGeneration
        previewTask?.cancel()
        acceptedSettings = nil
        isPreviewLoading = true
        let scope = DateScope(urls: snapshot.urls, extensionFilter: snapshot.extensionFilter)
        if snapshot.mode != .exifDate || (dateScope != nil && dateScope != scope) {
            cancelDateLoading()
        }
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self else { return }
                if snapshot.mode == .exifDate {
                    await self.loadDatesIfNeeded(for: snapshot)
                }
                try Task.checkCancellation()
                let rows = try await Self.previews(for: snapshot, sourceDates: self.sourceDates)
                try Task.checkCancellation()
                guard generation == self.previewGeneration, snapshot == self.settings else { return }
                self.previewRows = rows
                self.acceptedSettings = snapshot
                self.isPreviewLoading = false
                self.previewTask = nil
            } catch {
                // A newer generation owns the loading state and published rows.
            }
        }
    }

    func cancelPendingWork() {
        previewGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        cancelDateLoading()
        acceptedSettings = nil
        isPreviewLoading = true
    }

    private nonisolated static func previews(
        for settings: Settings, sourceDates: [URL: Date]
    ) async throws -> [Preview] {
        try await BackgroundWork.run {
            try buildPreviews(settings: settings, sourceDates: sourceDates)
        }
    }

    /// Checks only distinct targets outside the source set, never enumerating
    /// a directory. Disk results are not cached across passes (especially apply).
    private nonisolated static func buildPreviews(
        settings: Settings, sourceDates: [URL: Date]
    ) throws -> [Preview] {
        try Task.checkCancellation()
        let urls = settings.filteredURLs
        var rows: [Preview] = []
        rows.reserveCapacity(urls.count)

        // First pass: compute raw new names.
        var newNames: [String] = []
        newNames.reserveCapacity(urls.count)
        switch settings.mode {
        case .findReplace:
            let regex = settings.useRegex && !settings.find.isEmpty
                ? try? NSRegularExpression(
                    pattern: settings.find, options: settings.ignoreCase ? [.caseInsensitive] : []
                ) : nil
            for url in urls {
                try Task.checkCancellation()
                newNames.append(findReplaceName(for: url, settings: settings, regex: regex))
            }
        case .sequence:
            let width = numberWidth(start: settings.startNumber, count: urls.count)
            for (i, url) in urls.enumerated() {
                try Task.checkCancellation()
                newNames.append(sequenceName(for: url, index: i, width: width, settings: settings))
            }
        case .exifDate:
            let width = numberWidth(start: settings.dateStartNumber, count: urls.count)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = normalizedDateFormat(settings.dateFormat)
            for (i, url) in urls.enumerated() {
                try Task.checkCancellation()
                newNames.append(exifName(
                    for: url, index: i, width: width, settings: settings,
                    date: sourceDates[url], formatter: formatter
                ))
            }
        }

        // Second pass: collision detection.
        var sourcePaths: Set<String> = []
        sourcePaths.reserveCapacity(urls.count)
        // Count target names per parent directory.
        var targetCounts: [String: Int] = [:]
        targetCounts.reserveCapacity(urls.count)
        var targetPaths: [String] = []
        targetPaths.reserveCapacity(urls.count)
        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            sourcePaths.insert(url.standardizedFileURL.path)
            let target = url.deletingLastPathComponent()
                .appendingPathComponent(newNames[i]).standardizedFileURL.path
            targetCounts[target, default: 0] += 1
            targetPaths.append(target)
        }

        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            let oldName = url.lastPathComponent
            let newName = newNames[i]
            var error: String?
            if newName.isEmpty {
                error = "Empty name"
            } else if newName.contains("/") || newName == "." || newName == ".." || newName.contains("\0") {
                error = "Invalid name"
            } else {
                let targetPath = targetPaths[i]
                if targetCounts[targetPath, default: 0] > 1 {
                    error = "Duplicate target"
                } else if !sourcePaths.contains(targetPath),
                          FileManager.default.fileExists(atPath: targetPath) {
                    error = "Already exists"
                }
            }
            rows.append(Preview(id: url, oldName: oldName, newName: newName, error: error))
        }
        return rows
    }

    /// True when at least one file would be renamed and none are errored.
    var canApply: Bool {
        !isPreviewLoading && !isLoadingDates && !isApplying && acceptedSettings == settings
            && previewRows.contains(where: { $0.changed }) && !previewRows.contains(where: { $0.error != nil })
    }

    // MARK: - Name builders

    private nonisolated static func findReplaceName(
        for url: URL, settings: Settings, regex: NSRegularExpression?
    ) -> String {
        let fullName = url.lastPathComponent
        guard !settings.find.isEmpty else { return fullName }
        // Operate only on the name without its extension so the suffix
        // (e.g. ".mp4") is never matched or altered by the find pattern.
        let ext = url.pathExtension
        let base = ext.isEmpty ? fullName : String(fullName.dropLast(ext.count + 1))
        let newBase: String
        if settings.useRegex {
            guard let re = regex else {
                return fullName
            }
            let range = NSRange(base.startIndex..., in: base)
            // Progress callbacks also let cancellation interrupt a slow regex.
            var out = ""
            var lastEnd = base.startIndex
            re.enumerateMatches(in: base, options: [.reportProgress], range: range) { match, _, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                guard let match, let r = Range(match.range, in: base) else { return }
                out += base[lastEnd..<r.lowerBound]
                out += Self.expandTemplate(settings.replacement, match: match, in: base)
                lastEnd = r.upperBound
            }
            out += base[lastEnd...]
            newBase = out
        } else {
            let options: String.CompareOptions = settings.ignoreCase ? [.caseInsensitive] : []
            newBase = base.replacingOccurrences(of: settings.find, with: settings.replacement, options: options)
        }
        return ext.isEmpty ? newBase : "\(newBase).\(ext)"
    }

    /// Expands a Find & Replace template against a single regex match.
    ///
    /// Supported tokens:
    /// - `$0`…`$N` / `${N}` — the captured text of group *N*.
    /// - `${N:0Wd}` — group *N* zero-padded to width *W* (e.g. `${1:02d}`).
    /// - `${N:Wd}` / `${N:W}` — group *N* space-padded to width *W*.
    /// - `$$` — a literal `$`.
    nonisolated static func expandTemplate(_ template: String, match: NSTextCheckingResult, in source: String) -> String {
        func group(_ n: Int) -> String {
            guard n >= 0, n < match.numberOfRanges else { return "" }
            let r = match.range(at: n)
            guard r.location != NSNotFound, let sr = Range(r, in: source) else { return "" }
            return String(source[sr])
        }

        let chars = Array(template)
        var result = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "$", i + 1 < chars.count else {
                result.append(c)
                i += 1
                continue
            }
            let next = chars[i + 1]
            if next == "$" {
                result.append("$")
                i += 2
            } else if next == "{" {
                if let close = chars[(i + 2)...].firstIndex(of: "}") {
                    let inner = String(chars[(i + 2)..<close])
                    result.append(expandGroupSpec(inner, group: group))
                    i = close + 1
                } else {
                    result.append(c)
                    i += 1
                }
            } else if next.isNumber {
                var j = i + 1
                var num = ""
                while j < chars.count, chars[j].isNumber {
                    num.append(chars[j])
                    j += 1
                }
                if let n = Int(num) { result.append(group(n)) }
                i = j
            } else {
                result.append(c)
                i += 1
            }
        }
        return result
    }

    /// Expands the inside of a `${…}` token, e.g. `"1"` or `"1:02d"`.
    private nonisolated static func expandGroupSpec(_ spec: String, group: (Int) -> String) -> String {
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let n = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return "" }
        let value = group(n)
        guard parts.count == 2 else { return value }
        let format = parts[1]
        let zeroFill = format.hasPrefix("0")
        let widthDigits = format.filter(\.isNumber)
        guard let width = Int(widthDigits), value.count < width else { return value }
        let pad = String(repeating: zeroFill ? "0" : " ", count: width - value.count)
        return pad + value
    }


    private nonisolated static func sequenceName(
        for url: URL, index: Int, width: Int, settings: Settings
    ) -> String {
        let ext = url.pathExtension
        let number = String(format: "%0\(width)d", settings.startNumber + index)
        let base = "\(settings.prefix)\(number)\(settings.suffix)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private nonisolated static func exifName(
        for url: URL, index: Int, width: Int, settings: Settings,
        date: Date?, formatter: DateFormatter
    ) -> String {
        let ext = url.pathExtension
        let number = String(format: "%0\(width)d", settings.dateStartNumber + index)
        let datePart: String
        if let date {
            datePart = formatter.string(from: date)
        } else {
            datePart = "nodate"
        }
        let sep = settings.useSeparator ? settings.separator : ""
        let base = "\(datePart)\(sep)\(number)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private nonisolated static func numberWidth(start: Int, count: Int) -> Int {
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
        guard canApply, let snapshot = acceptedSettings else {
            return ([], ["The rename preview is not ready. Review the preview and try again."])
        }
        let generation = previewGeneration
        isApplying = true
        defer { isApplying = false }
        let validated: [Preview]
        do {
            validated = try await Self.previews(for: snapshot, sourceDates: sourceDates)
            try Task.checkCancellation()
        } catch {
            return ([], ["Could not validate renames: \(error.localizedDescription)"])
        }
        guard generation == previewGeneration, snapshot == settings else {
            return ([], ["The rename settings changed. Review the updated preview and try again."])
        }
        previewRows = validated
        let validationErrors = validated.compactMap { row in
            row.error.map { "\(row.oldName): \($0)" }
        }
        guard validationErrors.isEmpty else { return ([], validationErrors) }
        let rows = validated.filter { $0.changed }
        guard !rows.isEmpty else { return ([], ["No files need to be renamed."]) }
        let plan = rows.map { (from: $0.id, toName: $0.newName) }

        // Once staging starts, finish both passes even if the caller is cancelled.
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
