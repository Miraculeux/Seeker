import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VideoSummaryFrame: Sendable, Identifiable {
    let seconds: Double
    let image: CGImage
    var id: Double { seconds }
}

struct VideoSummary: Sendable {
    let duration: Double
    let frames: [VideoSummaryFrame]
    var warnings: [String]
}

enum VideoSummaryService {
    static let nativeExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let supportedExtensions: Set<String> = nativeExtensions.union([
        "mkv", "webm", "avi", "mpg", "mpeg", "ts", "mts", "m2ts", "wmv",
        "flv", "vob", "ogv", "3gp", "3g2", "mxf", "asf", "divx", "f4v"
    ])
    static let maximumFrames = 16

    static func supports(_ file: FileItem) -> Bool {
        !file.isDirectory && supportedExtensions.contains(file.url.pathExtension.lowercased())
    }

    enum SummaryError: LocalizedError {
        case unsupported, invalidVideo, noUsableFrames, imageProcessing, sourceChanged
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: "Choose a supported video file, such as MP4, MOV, M4V, MKV, WebM or AVI."
            case .invalidVideo: "This file has no readable video track or valid duration."
            case .noUsableFrames: "No usable summary frames were found. The video may be black, very blurred, or use an unsupported codec."
            case .imageProcessing: "A video frame could not be analyzed or encoded."
            case .sourceChanged: "The video changed during generation. Please generate the summary again."
            case .decodingFailed(let detail): "No video frames could be decoded: \(detail)"
            }
        }
    }

    struct Candidate: Sendable {
        let frame: VideoSummaryFrame
        let hash: UInt64
        let brightness: Double
        let quality: Double
    }

    static func sampleTimes(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let desired = max(16, ceil(duration / 30))
        let count = Int(min(240, min(desired, max(1, ceil(duration / 0.5)))))
        return (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "--:--" }
        let value = Int(seconds)
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }

    static func analyze(_ frame: VideoSummaryFrame) throws -> Candidate? {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(frame.image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { throw SummaryError.imageProcessing }
        let brightness = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        let clipped = pixels.filter { $0 < 8 || $0 > 247 }.count
        guard brightness > 6, brightness < 249,
              Double(clipped) / Double(pixels.count) < 0.98 else { return nil }

        var sum = 0.0
        var squaredSum = 0.0
        for y in 1..<(size - 1) {
            for x in 1..<(size - 1) {
                let i = y * size + x
                let laplacian = Double(pixels[i - 1]) + Double(pixels[i + 1])
                    + Double(pixels[i - size]) + Double(pixels[i + size]) - 4 * Double(pixels[i])
                sum += laplacian
                squaredSum += laplacian * laplacian
            }
        }
        let count = Double((size - 2) * (size - 2))
        let sharpness = max(0, squaredSum / count - pow(sum / count, 2))
        guard sharpness >= 8 else { return nil }
        guard let hash = SimilarImageFinder.perceptualHash(image: frame.image) else {
            throw SummaryError.imageProcessing
        }
        return Candidate(frame: frame, hash: hash, brightness: brightness, quality: sharpness)
    }

    static func select(_ candidates: [Candidate], duration: Double) -> [VideoSummaryFrame] {
        guard duration.isFinite, duration > 0 else { return [] }
        let ranked = candidates.sorted {
            $0.quality == $1.quality ? $0.frame.seconds < $1.frame.seconds : $0.quality > $1.quality
        }
        var selected: [Candidate] = []
        var occupiedBins: Set<Int> = []
        for candidate in ranked {
            let bin = min(maximumFrames - 1, max(0, Int(candidate.frame.seconds / duration * Double(maximumFrames))))
            guard !occupiedBins.contains(bin),
                  !selected.contains(where: {
                      ($0.hash ^ candidate.hash).nonzeroBitCount <= 6
                          && abs($0.brightness - candidate.brightness) < 12
                  }) else { continue }
            selected.append(candidate)
            occupiedBins.insert(bin)
        }
        return selected.map(\.frame).sorted { $0.seconds < $1.seconds }
    }

    static func generate(
        url: URL,
        cache: VideoSummaryCache = .shared,
        useCache: Bool = true,
        ffmpegSearchDirectories: [URL]? = nil,
        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> VideoSummary {
        try Task.checkCancellation()
        guard supports(FileItem(url: url)) else { throw SummaryError.unsupported }
        let key = try VideoSummaryCache.key(for: url)
        var warnings: [String] = []
        if useCache {
            do {
                if let cached = try await cache.load(key: key) {
                    try Task.checkCancellation()
                    guard try VideoSummaryCache.key(for: url) == key else { throw SummaryError.sourceChanged }
                    return cached
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch SummaryError.sourceChanged {
                throw SummaryError.sourceChanged
            } catch {
                warnings.append("The cached summary could not be read and will be regenerated: \(error.localizedDescription)")
            }
        }
        var summary: VideoSummary
        if nativeExtensions.contains(url.pathExtension.lowercased()) {
            do {
                summary = try await nativeSummary(url: url, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch SummaryError.noUsableFrames {
                throw SummaryError.noUsableFrames
            } catch SummaryError.imageProcessing {
                throw SummaryError.imageProcessing
            } catch {
                try Task.checkCancellation()
                let nativeFailure = error.localizedDescription
                do {
                    summary = try await ffmpegSummary(
                        url: url, searchDirectories: ffmpegSearchDirectories, progress: progress
                    )
                    summary.warnings.append("The macOS decoder failed; FFmpeg was used instead: \(nativeFailure)")
                } catch FFmpegVideoBackend.BackendError.missingTools {
                    throw FFmpegVideoBackend.BackendError.missingTools(nativeFailure: nativeFailure)
                }
            }
        } else {
            summary = try await ffmpegSummary(url: url, searchDirectories: ffmpegSearchDirectories, progress: progress)
        }
        try Task.checkCancellation()
        guard try VideoSummaryCache.key(for: url) == key else { throw SummaryError.sourceChanged }
        do {
            try await cache.store(summary, key: key)
        } catch {
            summary.warnings.append("The summary could not be cached: \(error.localizedDescription)")
        }
        summary.warnings.insert(contentsOf: warnings, at: 0)
        try Task.checkCancellation()
        return summary
    }

    private static func ffmpegSummary(
        url: URL, searchDirectories: [URL]?,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> VideoSummary {
        let backend = FFmpegVideoBackend(tools: try FFmpegTools.discover(in: searchDirectories ?? FFmpegTools.searchDirectories))
        let metadata = try await backend.metadata(for: url)
        return try await sample(duration: metadata.duration, progress: progress) { seconds in
            try await backend.image(for: url, at: seconds, metadata: metadata)
        }
    }

    private static func nativeSummary(
        url: URL, progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> VideoSummary {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw SummaryError.invalidVideo
        }
        let decoder = VideoSummaryDecoder(url: url)
        return try await withTaskCancellationHandler { @Sendable in
            try await sample(duration: duration, progress: progress) { seconds in
                try await decoder.image(at: seconds)
            }
        } onCancel: {
            Task { await decoder.cancel() }
        }
    }

    private static func sample(
        duration: Double,
        progress: @escaping @Sendable (Int, Int) async -> Void,
        decode: @escaping @Sendable (Double) async throws -> (image: CGImage, actualTime: CMTime)
    ) async throws -> VideoSummary {
        var warnings: [String] = []
        let times = sampleTimes(duration: duration)
        var candidates: [Candidate] = []
        var failures = 0
        var lastFailure = ""
        for (index, seconds) in times.enumerated() {
            try Task.checkCancellation()
            let decoded: (image: CGImage, actualTime: CMTime)
            do {
                decoded = try await decode(seconds)
            } catch {
                try Task.checkCancellation()
                failures += 1
                lastFailure = error.localizedDescription
                await progress(index + 1, times.count)
                continue
            }
            try Task.checkCancellation()
            let actualSeconds = decoded.actualTime.seconds
            guard actualSeconds.isFinite, actualSeconds >= 0 else { throw SummaryError.invalidVideo }
            if let candidate = try analyze(VideoSummaryFrame(seconds: actualSeconds, image: decoded.image)) {
                candidates.append(candidate)
            }
            await progress(index + 1, times.count)
        }
        let frames = select(candidates, duration: duration)
        guard !frames.isEmpty else {
            if failures == times.count {
                throw SummaryError.decodingFailed(lastFailure)
            }
            throw SummaryError.noUsableFrames
        }
        if failures > 0 {
            warnings.append("\(failures) of \(times.count) samples could not be decoded: \(lastFailure)")
        }
        try Task.checkCancellation()
        return VideoSummary(duration: duration, frames: frames, warnings: warnings)
    }
}

private actor VideoSummaryDecoder {
    private let generator: AVAssetImageGenerator
    private var isCancelled = false

    init(url: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
    }

    func image(at seconds: Double) async throws -> (image: CGImage, actualTime: CMTime) {
        guard !isCancelled else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(
                forTimes: [NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))]
            ) { _, image, actualTime, result, error in
                switch result {
                case .succeeded:
                    if let image {
                        continuation.resume(returning: (image, actualTime))
                    } else {
                        continuation.resume(throwing: VideoSummaryService.SummaryError.imageProcessing)
                    }
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .failed:
                    continuation.resume(throwing: error ?? VideoSummaryService.SummaryError.invalidVideo)
                @unknown default:
                    continuation.resume(throwing: VideoSummaryService.SummaryError.invalidVideo)
                }
            }
        }
    }

    func cancel() {
        isCancelled = true
        generator.cancelAllCGImageGeneration()
    }
}

actor VideoSummaryCache {
    static let shared = VideoSummaryCache()
    nonisolated let directory: URL
    private let maximumBytes: Int

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.seeker.app")
        .appendingPathComponent("video-summaries", isDirectory: true),
         maximumBytes: Int = 128 * 1024 * 1024) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    private struct StoredFrame: Codable {
        let seconds: Double
        let jpeg: Data
    }

    private struct StoredSummary: Codable {
        let duration: Double
        let frames: [StoredFrame]
        let warnings: [String]
    }

    static func key(for url: URL) throws -> String {
        // URL resource values can retain stale metadata across a source edit.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        let identity = "v1|\(url.standardizedFileURL.path)|\(size)|\(modified.timeIntervalSince1970)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load(key: String) throws -> VideoSummary? {
        let url = directory.appendingPathComponent(key).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stored = try JSONDecoder().decode(StoredSummary.self, from: Data(contentsOf: url))
        guard stored.duration.isFinite, stored.duration > 0,
              !stored.frames.isEmpty, stored.frames.count <= VideoSummaryService.maximumFrames else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let frames = try stored.frames.map { frame in
            guard frame.seconds.isFinite, frame.seconds >= 0, frame.seconds <= stored.duration,
                  let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return VideoSummaryFrame(seconds: frame.seconds, image: image)
        }
        return VideoSummary(duration: stored.duration, frames: frames, warnings: stored.warnings)
    }

    func currentSizeBytes() throws -> Int64 {
        try cacheEntries().reduce(0) { $0 + Int64($1.values.fileSize ?? 0) }
    }

    func clear() throws {
        for entry in try cacheEntries() {
            try FileManager.default.removeItem(at: entry.url)
        }
    }

    private func cacheEntries() throws -> [(url: URL, values: URLResourceValues)] {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey
        ]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys)
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        return try files.filter { $0.pathExtension == "json" }.map { url in
            (url: url, values: try url.resourceValues(forKeys: keys))
        }.filter { $0.values.isRegularFile == true && $0.values.isSymbolicLink != true }
    }

    func store(_ summary: VideoSummary, key: String) throws {
        let frames = try summary.frames.map { frame in
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw VideoSummaryService.SummaryError.imageProcessing
            }
            CGImageDestinationAddImage(destination, frame.image, [
                kCGImageDestinationLossyCompressionQuality: 0.85
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw VideoSummaryService.SummaryError.imageProcessing }
            return StoredFrame(seconds: frame.seconds, jpeg: data as Data)
        }
        let data = try JSONEncoder().encode(StoredSummary(
            duration: summary.duration, frames: frames, warnings: summary.warnings
        ))
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(key).appendingPathExtension("json"), options: .atomic)
        let entries = try cacheEntries().sorted {
            ($0.values.contentModificationDate ?? .distantPast) < ($1.values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + Int64($1.values.fileSize ?? 0) }
        for entry in entries where total > Int64(maximumBytes) {
            try fm.removeItem(at: entry.url)
            total -= Int64(entry.values.fileSize ?? 0)
        }
    }
}
