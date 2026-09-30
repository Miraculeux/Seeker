import AVFoundation
import Foundation
import ImageIO
import OSLog
import Synchronization

struct FFmpegTools: Sendable {
    let ffmpeg: URL
    let ffprobe: URL

    static var searchDirectories: [URL] {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (paths.filter { $0.hasPrefix("/") } + [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent("bin").path
        ]).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func discover(in directories: [URL] = searchDirectories) throws -> FFmpegTools {
        func executable(_ name: String, in directories: [URL]) -> URL? {
            directories.lazy.map { $0.appendingPathComponent(name) }.first { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
            }
        }
        guard let ffmpeg = executable("ffmpeg", in: directories),
              let ffprobe = executable("ffprobe", in: [ffmpeg.deletingLastPathComponent()] + directories) else {
            throw FFmpegVideoBackend.BackendError.missingTools(nativeFailure: nil)
        }
        return FFmpegTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }
}

struct FFmpegVideoBackend: Sendable {
    let tools: FFmpegTools

    enum BackendError: LocalizedError {
        case missingTools(nativeFailure: String?)
        case commandFailed(tool: String, status: Int32, detail: String)
        case timedOut(tool: String)
        case invalidMetadata, invalidImage, invalidTimestamp

        var errorDescription: String? {
            switch self {
            case .missingTools(let nativeFailure):
                let detail = nativeFailure.map { "\nThe macOS decoder also failed: \($0)" } ?? ""
                return "This video needs FFmpeg. Seeker could not find both ffmpeg and ffprobe. If Homebrew is installed, run:\n\nbrew install ffmpeg\n\nThen click Generate Again. Seeker checks PATH, /opt/homebrew/bin, /usr/local/bin, /opt/local/bin, ~/.local/bin and ~/bin.\(detail)"
            case .commandFailed(let tool, let status, let detail):
                return "\(tool) failed (exit \(status)): \(detail)"
            case .timedOut(let tool):
                return "\(tool) exceeded the time limit. Check the video and try again."
            case .invalidMetadata:
                return "FFprobe did not report a valid duration and readable video stream."
            case .invalidImage:
                return "FFmpeg did not produce a readable video frame."
            case .invalidTimestamp:
                return "FFmpeg did not report a valid timestamp for the extracted frame."
            }
        }
    }

    struct Metadata: Sendable {
        let duration: Double
        let startTime: Double
        let streamIndex: Int
    }

    private struct Probe: Decodable {
        struct Format: Decodable {
            let duration: String?
            let start_time: String?
        }
        struct Stream: Decodable {
            struct Disposition: Decodable { let attached_pic: Int? }
            let index: Int
            let codec_type: String?
            let duration: String?
            let disposition: Disposition?
        }
        let format: Format?
        let streams: [Stream]
    }

    func metadata(for url: URL) async throws -> Metadata {
        let output = try await FFmpegProcess.run(executable: tools.ffprobe, arguments: [
            "-v", "error", "-show_entries",
            "format=duration,start_time:stream=index,codec_type,duration:stream_disposition=attached_pic",
            "-of", "json", url.path
        ])
        let probe = try JSONDecoder().decode(Probe.self, from: output.stdout)
        guard let stream = probe.streams.first(where: {
            $0.codec_type == "video" && ($0.disposition?.attached_pic ?? 0) == 0
        }), let duration = (probe.format?.duration.flatMap(Double.init) ?? stream.duration.flatMap(Double.init)),
              duration.isFinite, duration > 0 else { throw BackendError.invalidMetadata }
        let start = probe.format?.start_time.flatMap(Double.init) ?? 0
        guard start.isFinite else { throw BackendError.invalidMetadata }
        return Metadata(duration: duration, startTime: start, streamIndex: stream.index)
    }

    func image(for url: URL, at seconds: Double, metadata: Metadata) async throws -> (image: CGImage, actualTime: CMTime) {
        // Match native seek tolerance, including low-frame-rate videos near EOF.
        let time = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds - 0.25))
        let filter = "scale=w='max(2,trunc(min(480,480*dar)/2)*2)':h='max(2,trunc(min(480,480/dar)/2)*2)',setsar=1,showinfo"
        let output = try await FFmpegProcess.run(executable: tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "info", "-nostdin", "-ss", time, "-copyts",
            "-i", url.path, "-map", "0:\(metadata.streamIndex)", "-an", "-sn", "-dn",
            "-frames:v", "1", "-vf", filter, "-fps_mode", "passthrough",
            "-threads", "1", "-f", "image2pipe", "-c:v", "png", "pipe:1"
        ])
        guard let source = CGImageSourceCreateWithData(output.stdout as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BackendError.invalidImage }
        let log = String(decoding: output.stderr, as: UTF8.self)
        let pattern = try NSRegularExpression(pattern: #"pts_time:\s*([-+0-9.eE]+)"#)
        guard let match = pattern.firstMatch(in: log, range: NSRange(log.startIndex..., in: log)),
              let range = Range(match.range(at: 1), in: log),
              let pts = Double(log[range]), pts.isFinite else { throw BackendError.invalidTimestamp }
        let actual = pts - metadata.startTime
        guard actual >= -0.001, actual <= metadata.duration + 0.5 else { throw BackendError.invalidTimestamp }
        return (image, CMTime(seconds: max(0, actual), preferredTimescale: 600))
    }
}

enum FFmpegProcess {
    struct Output: Sendable {
        let stdout: Data
        let stderr: Data
    }

    private static let logger = Logger(subsystem: "com.seeker.app", category: "VideoSummary")

    static func run(executable: URL, arguments: [String], timeout: Double = 60) async throws -> Output {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Seeker-ffmpeg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { logger.error("Could not remove FFmpeg temporary output: \(error.localizedDescription, privacy: .public)") }
        }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        defer {
            do { try stdout.close() }
            catch { logger.error("Could not close FFmpeg stdout: \(error.localizedDescription, privacy: .public)") }
        }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            do { try stderr.close() }
            catch { logger.error("Could not close FFmpeg stderr: \(error.localizedDescription, privacy: .public)") }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // Files avoid deadlocks when either output exceeds a pipe's buffer.
        process.standardOutput = stdout
        process.standardError = stderr
        let expired = Mutex(false)
        let timer = Task.detached {
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch is CancellationError { return }
            catch {
                logger.error("FFmpeg timeout timer failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            expired.withLock { $0 = true }
            if process.isRunning { process.terminate() }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await BackgroundWork.run {
                try process.run()
                if Task.isCancelled || expired.withLock({ $0 }), process.isRunning { process.terminate() }
                process.waitUntilExit()
                try Task.checkCancellation()
                if expired.withLock({ $0 }) {
                    throw FFmpegVideoBackend.BackendError.timedOut(tool: executable.lastPathComponent)
                }
                let output = Output(stdout: try Data(contentsOf: stdoutURL), stderr: try Data(contentsOf: stderrURL))
                guard process.terminationStatus == 0 else {
                    let detail = String(decoding: output.stderr.suffix(4096), as: UTF8.self)
                    throw FFmpegVideoBackend.BackendError.commandFailed(
                        tool: executable.lastPathComponent, status: process.terminationStatus,
                        detail: detail.isEmpty ? "No diagnostic output was provided." : detail
                    )
                }
                return output
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
