import Foundation
import UniformTypeIdentifiers
import AppKit

/// Imports drag-and-drop payloads that aren't local files — e.g. images
/// dragged from a web browser. Two paths:
///  1. Embedded image data (`public.png`, `public.jpeg`, `public.tiff`, …)
///     written directly to a new file in the destination directory.
///  2. Remote URLs (`public.url` http/https) downloaded via URLSession.
enum BrowserDropImporter {

    /// Type identifiers we'll try to pull data out of, in priority order.
    /// Concrete image formats first so we keep the original encoding; then
    /// `public.image` for generic images; finally `public.url` for remote
    /// download. `public.file-url` is intentionally excluded — local-file
    /// drops are handled by the existing copy/move pipeline.
    static let imageTypes: [UTType] = [
        .png, .jpeg, .tiff, .gif, .webP, .heic, .bmp, .svg
    ]

    /// Process all providers in parallel, then call `completion` on the
    /// main queue if at least one save succeeded.
    static func importProviders(
        _ providers: [NSItemProvider],
        into destDir: URL,
        completion: @escaping () -> Void
    ) {
        let group = DispatchGroup()
        let savedLock = NSLock()
        var savedAny = false

        for provider in providers {
            group.enter()
            save(provider: provider, into: destDir) { ok in
                savedLock.lock()
                savedAny = savedAny || ok
                savedLock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if savedAny { completion() }
        }
    }

    private static func save(
        provider: NSItemProvider,
        into destDir: URL,
        completion: @escaping (Bool) -> Void
    ) {
        let suggested = sanitizeName(provider.suggestedName)

        // 1. Concrete image data — preserve original encoding.
        for type in imageTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { completion(false); return }
                let ext = type.preferredFilenameExtension ?? "img"
                let name = ensureExtension(suggested ?? defaultImageName(ext: ext), ext: ext)
                completion(write(data, into: destDir, name: name))
            }
            return
        }

        // 2. Generic image (e.g. provider only advertises `public.image`).
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { completion(false); return }
                let ext = detectExtension(for: data) ?? "png"
                let name = ensureExtension(suggested ?? defaultImageName(ext: ext), ext: ext)
                completion(write(data, into: destDir, name: name))
            }
            return
        }

        // 3. URL → download via URLSession (browser image drag).
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    completion(false); return
                }
                download(url: url, into: destDir, suggested: suggested, completion: completion)
            }
            return
        }

        completion(false)
    }

    private static func download(
        url: URL,
        into destDir: URL,
        suggested: String?,
        completion: @escaping (Bool) -> Void
    ) {
        var request = URLRequest(url: url)
        // A real-looking UA + Referer to the image's own origin helps some
        // CDNs that block default URLSession requests.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605 Seeker",
            forHTTPHeaderField: "User-Agent"
        )
        if let origin = url.host.flatMap({ URL(string: "\(url.scheme ?? "https")://\($0)/") }) {
            request.setValue(origin.absoluteString, forHTTPHeaderField: "Referer")
        }

        let task = URLSession.shared.downloadTask(with: request) { tmpURL, response, error in
            guard error == nil, let tmpURL else { completion(false); return }

            var name: String = {
                if let s = suggested, !s.isEmpty { return s }
                let last = url.lastPathComponent
                if !last.isEmpty, last != "/" {
                    return sanitizeName(last) ?? "Download-\(timestamp())"
                }
                return "Download-\(timestamp())"
            }()

            if (name as NSString).pathExtension.isEmpty,
               let http = response as? HTTPURLResponse,
               let mime = http.value(forHTTPHeaderField: "Content-Type")?
                   .components(separatedBy: ";").first?
                   .trimmingCharacters(in: .whitespaces),
               let type = UTType(mimeType: mime),
               let ext = type.preferredFilenameExtension {
                name = "\(name).\(ext)"
            }

            let target = uniqueDestination(in: destDir, name: name)
            do {
                try FileManager.default.moveItem(at: tmpURL, to: target)
                completion(true)
            } catch {
                // moveItem can fail across filesystems; fall back to copy.
                do {
                    try FileManager.default.copyItem(at: tmpURL, to: target)
                    completion(true)
                } catch {
                    completion(false)
                }
            }
        }
        task.resume()
    }

    // MARK: - File writing

    private static func write(_ data: Data, into destDir: URL, name: String) -> Bool {
        let target = uniqueDestination(in: destDir, name: name)
        do {
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Name helpers

    /// Strip path separators / control chars so a malicious suggestedName
    /// can't escape `destDir`. Returns nil for empty / nil input.
    private static func sanitizeName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: " ._-()[]{}+&,'@#")
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func ensureExtension(_ name: String, ext: String) -> String {
        let current = (name as NSString).pathExtension.lowercased()
        if current == ext.lowercased() { return name }
        if current.isEmpty { return "\(name).\(ext)" }
        return name
    }

    private static func defaultImageName(ext: String) -> String {
        "Image-\(timestamp()).\(ext)"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// `<stem>.<ext>` → `<stem> 2.<ext>` → `<stem> 3.<ext>` … on collision.
    static func uniqueDestination(in dir: URL, name: String) -> URL {
        let candidate = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let ns = name as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 2
        while true {
            let suffix = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let url = dir.appendingPathComponent(suffix)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// Magic-number sniff for generic `public.image` data.
    private static func detectExtension(for data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return nil }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if (b[0] == 0x49 && b[1] == 0x49) || (b[0] == 0x4D && b[1] == 0x4D) { return "tiff" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b.count >= 12,
           b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b[0] == 0x42, b[1] == 0x4D { return "bmp" }
        return nil
    }
}
