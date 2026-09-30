import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import XCTest
@testable import Seeker

final class VideoSummaryTests: XCTestCase, @unchecked Sendable {
    func testSamplingCoversHourWithoutEndpointsAndCapsLongVideos() {
        let times = VideoSummaryService.sampleTimes(duration: 3600)
        XCTAssertEqual(times.count, 120)
        XCTAssertEqual(times.first, 15)
        XCTAssertEqual(times.last, 3585)
        XCTAssertEqual(VideoSummaryService.sampleTimes(duration: 36000).count, 240)
        XCTAssertEqual(VideoSummaryService.sampleTimes(duration: 0.1), [0.05])
        XCTAssertTrue(VideoSummaryService.sampleTimes(duration: .nan).isEmpty)
        XCTAssertTrue(VideoSummaryService.sampleTimes(duration: .infinity).isEmpty)
        XCTAssertTrue(VideoSummaryService.sampleTimes(duration: 0).isEmpty)
        XCTAssertEqual(VideoSummaryService.timestamp(3661.9), "01:01:01")
    }

    func testQualityFilterRejectsBlackWhiteAndSmoothFrames() throws {
        for style in [ImageStyle.black, .white, .smooth] {
            let image = try image(style)
            XCTAssertNil(try VideoSummaryService.analyze(.init(seconds: 0, image: image)))
        }
        let sharp = try image(.pattern(1))
        XCTAssertNotNil(try VideoSummaryService.analyze(.init(seconds: 0, image: sharp)))
    }

    func testSelectionBalancesTimeQualityAndDeduplication() throws {
        let frame = try image(.pattern(1))
        let candidates: [VideoSummaryService.Candidate] = [
            .init(frame: .init(seconds: 1, image: frame), hash: 0, brightness: 100, quality: 10),
            .init(frame: .init(seconds: 2, image: frame), hash: .max, brightness: 100, quality: 20),
            .init(frame: .init(seconds: 20, image: frame), hash: .max, brightness: 100, quality: 15),
            .init(frame: .init(seconds: 50, image: frame), hash: 0xAAAAAAAAAAAAAAAA, brightness: 100, quality: 30),
            .init(frame: .init(seconds: 90, image: frame), hash: 0x5555555555555555, brightness: 100, quality: 40)
        ]
        let selected = VideoSummaryService.select(candidates, duration: 100)
        XCTAssertEqual(selected.map(\.seconds), [2, 50, 90])
        let many = (0..<40).map { index in
            VideoSummaryService.Candidate(
                frame: .init(seconds: Double(index) + 0.5, image: frame),
                hash: UInt64(index), brightness: Double(index) * 20, quality: Double(index) + 10
            )
        }
        let bounded = VideoSummaryService.select(many, duration: 40)
        XCTAssertEqual(bounded.count, 16)
        XCTAssertLessThan(try XCTUnwrap(bounded.first).seconds, 3)
        XCTAssertGreaterThan(try XCTUnwrap(bounded.last).seconds, 37)
    }

    func testEligibilityAllowsSupportedVideoContainersAndNotDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for ext in ["MP4", "mov", "m4v", "mkv", "webm", "avi", "m2ts", "mxf"] {
            let url = fixture.root.appendingPathComponent("clip.\(ext)")
            try Data().write(to: url)
            XCTAssertTrue(VideoSummaryService.supports(FileItem(url: url)))
        }
        for ext in ["mp3", "png", "txt"] {
            XCTAssertFalse(VideoSummaryService.supports(FileItem(url: fixture.root.appendingPathComponent("clip.\(ext)"))))
        }
        let directory = fixture.root.appendingPathComponent("folder.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(VideoSummaryService.supports(FileItem(url: directory)))
    }

    func testRealVideoGenerationCacheReuseAndSourceInvalidation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try await video(in: fixture)
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"))
        let original = try Data(contentsOf: url)
        let summary = try await VideoSummaryService.generate(url: url, cache: cache)
        XCTAssertEqual(summary.duration, 8, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(summary.frames.count, 2)
        XCTAssertLessThan(summary.frames.count, 16)
        XCTAssertTrue(summary.warnings.isEmpty)
        XCTAssertEqual(summary.frames.map(\.seconds), summary.frames.map(\.seconds).sorted())
        XCTAssertTrue(summary.frames.allSatisfy { $0.seconds >= 2 && $0.seconds < summary.duration })
        XCTAssertTrue(summary.frames.allSatisfy { max($0.image.width, $0.image.height) <= 480 })
        XCTAssertEqual(try Data(contentsOf: url), original)

        let reused = try await VideoSummaryService.generate(url: url, cache: cache) { _, _ in
            XCTFail("A cache hit should not decode samples")
        }
        XCTAssertEqual(reused.frames.map(\.seconds), summary.frames.map(\.seconds))
        let previousKey = try VideoSummaryCache.key(for: url)
        let modified = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(2)], ofItemAtPath: url.path)
        XCTAssertNotEqual(try VideoSummaryCache.key(for: url), previousKey)
        let stale = try await cache.load(key: VideoSummaryCache.key(for: url))
        XCTAssertNil(stale)
    }

    func testCorruptCacheRegeneratesWithVisibleWarningAndForcedRegenerationBypassesCache() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try await video(in: fixture)
        let directory = fixture.root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = VideoSummaryCache(directory: directory)
        let cached = directory.appendingPathComponent(try VideoSummaryCache.key(for: url)).appendingPathExtension("json")
        try Data("broken".utf8).write(to: cached)
        let recovered = try await VideoSummaryService.generate(url: url, cache: cache)
        XCTAssertTrue(recovered.warnings.contains { $0.contains("cached summary could not be read") })
        let forced = try await VideoSummaryService.generate(url: url, cache: cache, useCache: false)
        XCTAssertTrue(forced.warnings.isEmpty)
    }

    func testInvalidBlackAndCancelledVideosReportFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let malformed = fixture.root.appendingPathComponent("broken.mp4")
        try Data("not a movie".utf8).write(to: malformed)
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"))
        do {
            _ = try await VideoSummaryService.generate(url: malformed, cache: cache)
            XCTFail("Malformed videos must report an error")
        } catch {}
        let black = try await video(in: fixture, allBlack: true)
        do {
            _ = try await VideoSummaryService.generate(url: black, cache: cache)
            XCTFail("A black video must not produce a success-shaped result")
        } catch VideoSummaryService.SummaryError.noUsableFrames {}
        let task = Task {
            try await VideoSummaryService.generate(url: malformed, cache: cache)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled generation must throw")
        } catch is CancellationError {}
    }

    func testCacheBudgetAndWriteFailures() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let frame = VideoSummaryFrame(seconds: 1, image: try image(.pattern(3)))
        let summary = VideoSummary(duration: 10, frames: [frame], warnings: [])
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"), maximumBytes: 1)
        try await cache.store(summary, key: "test")
        let evicted = try await cache.load(key: "test")
        XCTAssertNil(evicted)

        let url = try await video(in: fixture)
        let blocked = fixture.root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let result = try await VideoSummaryService.generate(
            url: url, cache: VideoSummaryCache(directory: blocked), useCache: false
        )
        XCTAssertFalse(result.frames.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("could not be cached") })
    }

    func testClearingSummaryCacheRemovesOnlyRegularJSONFilesAndCanRepopulate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("cache")
        let cache = VideoSummaryCache(directory: directory)
        let summary = VideoSummary(
            duration: 10, frames: [.init(seconds: 1, image: try image(.pattern(3)))], warnings: []
        )
        try await cache.store(summary, key: "summary")
        let corrupt = directory.appendingPathComponent("corrupt.json")
        try Data("broken cache".utf8).write(to: corrupt)
        let export = directory.appendingPathComponent("exported.png")
        try Data("export".utf8).write(to: export)
        let nested = directory.appendingPathComponent("folder.json")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appendingPathComponent("keep.txt")
        try Data("nested".utf8).write(to: nestedFile)
        let external = fixture.root.appendingPathComponent("source.mp4")
        try Data("source".utf8).write(to: external)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let stored = directory.appendingPathComponent("summary.json")
        let expectedSize = try Data(contentsOf: stored).count + Data(contentsOf: corrupt).count
        let size = try await cache.currentSizeBytes()
        XCTAssertEqual(size, Int64(expectedSize))

        try await cache.clear()
        let afterSize = try await cache.currentSizeBytes()
        let afterLoad = try await cache.load(key: "summary")
        XCTAssertEqual(afterSize, 0)
        XCTAssertNil(afterLoad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertEqual(try Data(contentsOf: external), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: export), Data("export".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(summary.frames.count, 1)

        try await cache.store(summary, key: "new")
        let repopulated = try await cache.load(key: "new")
        XCTAssertNotNil(repopulated)
    }

    func testMissingSummaryCacheSizeAndClearAreSafe() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("missing"))
        let initialSize = try await cache.currentSizeBytes()
        XCTAssertEqual(initialSize, 0)
        try await cache.clear()
        try await cache.clear()
        let finalSize = try await cache.currentSizeBytes()
        XCTAssertEqual(finalSize, 0)
    }

    @MainActor
    func testSettingsCacheModelRefreshesSizeAfterClear() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"))
        try await cache.store(VideoSummary(
            duration: 10, frames: [.init(seconds: 1, image: try image(.pattern(1)))], warnings: []
        ), key: "summary")
        let model = VideoSummaryCacheSettingsModel(cache: cache)
        await model.refresh()
        XCTAssertGreaterThan(try XCTUnwrap(model.bytes), 0)
        XCTAssertNil(model.errorMessage)
        await model.clear()
        XCTAssertEqual(model.bytes, 0)
        XCTAssertFalse(model.isClearing)
        XCTAssertFalse(model.sizeUnavailable)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testSettingsCacheModelSurfacesReadAndClearErrors() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let blocked = fixture.root.appendingPathComponent("not-a-directory")
        try Data("preserve".utf8).write(to: blocked)
        let model = VideoSummaryCacheSettingsModel(cache: VideoSummaryCache(directory: blocked))
        await model.refresh()
        XCTAssertNil(model.bytes)
        XCTAssertTrue(model.sizeUnavailable)
        XCTAssertTrue(model.errorMessage?.contains("Could not read") == true)
        await model.clear()
        XCTAssertFalse(model.isClearing)
        XCTAssertTrue(model.errorMessage?.contains("Could not clear") == true)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("preserve".utf8))
    }

    func testCancellationDuringSamplingDoesNotPersistPartialSummary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try await video(in: fixture)
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"))
        let task = Task {
            try await VideoSummaryService.generate(url: url, cache: cache) { completed, _ in
                if completed == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation during sampling must throw")
        } catch is CancellationError {}
        let partial = try await cache.load(key: VideoSummaryCache.key(for: url))
        XCTAssertNil(partial)
    }

    @MainActor
    func testModelPublishesResultAndReportsFailureWithoutKeepingOldFrames() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try await video(in: fixture)
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"))
        let model = VideoSummaryModel()
        await model.generate(url: url, useCache: false, cache: cache)
        XCTAssertNotNil(model.summary)
        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.completed, model.total)
        XCTAssertGreaterThan(model.total, 0)
        XCTAssertNil(model.message)
        await model.generate(url: fixture.root.appendingPathComponent("missing.mp4"), useCache: false, cache: cache)
        XCTAssertNil(model.summary)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isGenerating)
    }

    @MainActor
    func testSupersededGenerationCannotOverwriteNewResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try await video(in: fixture)
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"))
        let model = VideoSummaryModel()
        let first = Task { await model.generate(url: url, useCache: false, cache: cache) }
        await Task.yield()
        await model.generate(url: fixture.root.appendingPathComponent("missing.mp4"), useCache: false, cache: cache)
        await first.value
        XCTAssertNil(model.summary)
        XCTAssertNotNil(model.message)
        XCTAssertNotEqual(model.message, "Generation cancelled.")
        XCTAssertFalse(model.isGenerating)
    }

    func testPreferredVideoTransformIsAppliedToSummaryImages() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try await video(in: fixture, rotated: true)
        let summary = try await VideoSummaryService.generate(
            url: url, cache: VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"))
        )
        XCTAssertTrue(summary.frames.allSatisfy { $0.image.width == 90 && $0.image.height == 160 })
    }

    func testFFmpegDiscoveryRequiresBothExecutableToolsAndRejectsDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bin = fixture.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let ffmpeg = bin.appendingPathComponent("ffmpeg")
        let ffprobe = bin.appendingPathComponent("ffprobe")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: ffmpeg)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
        XCTAssertThrowsError(try FFmpegTools.discover(in: [bin]))
        try FileManager.default.createDirectory(at: ffprobe, withIntermediateDirectories: true)
        XCTAssertThrowsError(try FFmpegTools.discover(in: [bin]))
        try FileManager.default.removeItem(at: ffprobe)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: ffprobe)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ffprobe.path)
        XCTAssertThrowsError(try FFmpegTools.discover(in: [bin]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffprobe.path)
        let tools = try FFmpegTools.discover(in: [bin])
        XCTAssertEqual(tools.ffmpeg, ffmpeg)
        XCTAssertEqual(tools.ffprobe, ffprobe)
    }

    @MainActor
    func testMissingFFmpegProvidesInstallationPromptAndNativeVideosStillWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("clip.mkv")
        try Data().write(to: url)
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"))
        let model = VideoSummaryModel()
        await model.generate(url: url, useCache: false, cache: cache, ffmpegSearchDirectories: [])
        XCTAssertTrue(model.needsFFmpegInstallation)
        XCTAssertTrue(model.message?.contains("brew install ffmpeg") == true)
        XCTAssertTrue(model.message?.contains("ffprobe") == true)
        XCTAssertNil(model.summary)
        let native = try await video(in: fixture)
        await model.generate(url: native, useCache: false, cache: cache, ffmpegSearchDirectories: [])
        XCTAssertFalse(model.needsFFmpegInstallation)
        XCTAssertNotNil(model.summary)
        XCTAssertNil(model.message)
    }

    func testRealFFmpegVideoAndNativeCodecFallback() async throws {
        let tools: FFmpegTools
        do { tools = try FFmpegTools.discover() }
        catch { throw XCTSkip("FFmpeg integration test requires ffmpeg and ffprobe: \(error.localizedDescription)") }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try await video(in: fixture)
        let mkv = fixture.root.appendingPathComponent("sample with 'quotes';$value.mkv")
        _ = try await FFmpegProcess.run(executable: tools.ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-i", source.path, "-an", "-c:v", "ffv1", mkv.path
        ])
        let original = try Data(contentsOf: mkv)
        let cache = VideoSummaryCache(directory: fixture.root.appendingPathComponent("cache"))
        let result = try await VideoSummaryService.generate(url: mkv, cache: cache)
        XCTAssertEqual(result.duration, 8, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(result.frames.count, 2)
        XCTAssertTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
        XCTAssertTrue(result.frames.allSatisfy { $0.seconds >= 2 && $0.seconds < 8 })
        XCTAssertTrue(result.frames.allSatisfy { max($0.image.width, $0.image.height) <= 480 })
        XCTAssertEqual(try Data(contentsOf: mkv), original)
        let reused = try await VideoSummaryService.generate(url: mkv, cache: cache, ffmpegSearchDirectories: [])
        XCTAssertEqual(reused.frames.map(\.seconds), result.frames.map(\.seconds))

        let nonNativeCodec = fixture.root.appendingPathComponent("unsupported-codec.mp4")
        try FileManager.default.copyItem(at: mkv, to: nonNativeCodec)
        let fallback = try await VideoSummaryService.generate(url: nonNativeCodec, cache: cache)
        XCTAssertFalse(fallback.frames.isEmpty)
        XCTAssertTrue(fallback.warnings.contains { $0.contains("FFmpeg was used instead") })
        do {
            _ = try await VideoSummaryService.generate(
                url: nonNativeCodec, cache: cache, useCache: false, ffmpegSearchDirectories: []
            )
            XCTFail("A failed native decoder without FFmpeg must explain the missing dependency")
        } catch FFmpegVideoBackend.BackendError.missingTools(let failure) {
            XCTAssertNotNil(failure)
        }
    }

    func testFFmpegProcessReportsErrorsTimeoutAndCancellation() async throws {
        do {
            _ = try await FFmpegProcess.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
            XCTFail("A failed external tool must report an error")
        } catch FFmpegVideoBackend.BackendError.commandFailed(_, let status, let detail) {
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(detail.isEmpty)
        }
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        do {
            _ = try await FFmpegProcess.run(executable: sleep, arguments: ["5"], timeout: 0.1)
            XCTFail("A stalled tool must time out")
        } catch FFmpegVideoBackend.BackendError.timedOut {}
        let start = ContinuousClock.now
        let task = Task { try await FFmpegProcess.run(executable: sleep, arguments: ["5"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop the subprocess")
        } catch is CancellationError {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    @MainActor
    func testEntryPointRequiresSingleVideoAndHelperWindowIsIsolated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let video = fixture.root.appendingPathComponent("selected.MP4")
        let second = fixture.root.appendingPathComponent("second.mov")
        try Data().write(to: video)
        try Data().write(to: second)
        let state = AppState()
        state.activeExplorer.files = [FileItem(url: video), FileItem(url: second)]
        state.activeExplorer.selectedFileIDs = [video.absoluteString]
        XCTAssertTrue(state.canOpenVideoSummary)
        state.openVideoSummary()
        XCTAssertEqual(state.videoSummaryRequest?.url, video)
        XCTAssertEqual(state.videoSummaryRequest?.sourceWindowID, state.windowID)
        state.activeExplorer.selectedFileIDs.insert(second.absoluteString)
        XCTAssertFalse(state.canOpenVideoSummary)
        state.openVideoSummary(for: second)
        XCTAssertEqual(state.videoSummaryRequest?.url, second)
        let window = NSWindow()
        window.title = "Video Summary"
        XCTAssertTrue(AppDelegate.isHelperWindow(window))
        XCTAssertFalse(AppDelegate.isTriageWindow(window))
    }

    @MainActor
    func testExportProducesPNGWithExpectedContactSheetDimensions() throws {
        _ = NSApplication.shared
        let picture = try image(.pattern(2))
        let summary = VideoSummary(duration: 3600, frames: (0..<5).map {
            VideoSummaryFrame(seconds: Double($0) * 30, image: picture)
        }, warnings: [])
        let data = try VideoSummaryExporter.png(summary: summary, name: "Example.mp4")
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(output.width, 2000)
        XCTAssertEqual(output.height, 712)
    }

    private enum ImageStyle {
        case black, white, smooth, pattern(Int)
    }

    private func image(_ style: ImageStyle) throws -> CGImage {
        let width = 160
        let height = 90
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8
                switch style {
                case .black: value = 0
                case .white: value = 255
                case .smooth: value = UInt8(80 + x / 4)
                case .pattern(let seed):
                    let block = (x / 10) * 13 + (y / 10) * 37 + seed * 97
                    value = UInt8(30 + ((block * (block + seed * 19)) % 190))
                }
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func video(in fixture: Fixture, allBlack: Bool = false, rotated: Bool = false) async throws -> URL {
        let url = fixture.root.appendingPathComponent(allBlack ? "black.mp4" : "pattern.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 90
        ])
        if rotated {
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<16 {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(
                kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer
            ), kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let context = try XCTUnwrap(CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer), width: 160, height: 90,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            ))
            context.draw(try image(allBlack || index < 4 ? .black : .pattern(index / 4)),
                         in: CGRect(x: 0, y: 0, width: 160, height: 90))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    writer.cancelWriting()
                    throw NSError(domain: "VideoFixture", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Video fixture writer did not become ready."
                    ])
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 2)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 8, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw try XCTUnwrap(writer.error) }
        return url
    }

    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Seeker-video-summary-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
