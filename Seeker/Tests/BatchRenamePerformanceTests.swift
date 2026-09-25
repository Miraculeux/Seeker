import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Seeker

final class BatchRenamePerformanceTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testLiteralReplacementPreservesOrderExtensionsAndFiltering() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("Alpha-2.txt")
        let second = root.appendingPathComponent("ALPHA-1.JPG")
        let ignored = root.appendingPathComponent("ignore.png")
        let model = BatchRenamer(urls: [first, second, ignored])
        defer { model.cancelPendingWork() }
        model.extensionFilter = "*.jpg; .TXT"
        model.find = "alpha"
        model.replacement = "shot"
        model.requestPreview()
        XCTAssertTrue(model.isPreviewLoading)
        XCTAssertFalse(model.canApply)
        try await waitForPreview(model)
        XCTAssertEqual(model.previewRows.map(\.id), [first, second])
        XCTAssertEqual(model.previewRows.map(\.newName), ["shot-2.txt", "shot-1.JPG"])
        XCTAssertTrue(model.canApply)

        model.ignoreCase = false
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.previewRows.allSatisfy { $0.oldName == $0.newName })
    }

    @MainActor
    func testRegexTemplatesAndInvalidPatterns() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BatchRenamer(urls: [
            root.appendingPathComponent("Alpha-2.txt"),
            root.appendingPathComponent("ALPHA-1.JPG")
        ])
        defer { model.cancelPendingWork() }
        model.useRegex = true
        model.find = "alpha-(\\d+)"
        model.replacement = "frame_${1:03d}_$$"
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertEqual(model.previewRows.map(\.newName), ["frame_002_$.txt", "frame_001_$.JPG"])

        model.find = "["
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.previewRows.allSatisfy { $0.oldName == $0.newName && $0.error == nil })
    }

    @MainActor
    func testSequencePaddingAndStaleApplyProtection() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)
        let model = BatchRenamer(urls: [source, root.appendingPathComponent("another.JPG")])
        defer { model.cancelPendingWork() }
        model.mode = .sequence
        model.startNumber = 9
        model.prefix = "Seq"
        model.suffix = "-x"
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertEqual(model.previewRows.map(\.newName), ["Seq09-x.txt", "Seq10-x.JPG"])
        XCTAssertTrue(model.canApply)

        model.prefix = "unrequested-"
        XCTAssertFalse(model.canApply, "Even an edit without requestPreview must invalidate apply")
        let rejected = await model.apply()
        XCTAssertTrue(rejected.renamed.isEmpty)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")

        model.requestPreview()
        let pending = await model.apply()
        XCTAssertTrue(pending.renamed.isEmpty)
        XCTAssertFalse(model.canApply)
    }

    @MainActor
    func testEXIFCreationFallbackAndPositiveNegativeMetadataCaching() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("photo.jpg")
        let absent = root.appendingPathComponent("missing.jpg")
        let fallback = root.appendingPathComponent("plain.txt")
        try makeImage(at: image, date: "2020:02:03 04:05:06")
        try Data("synthetic".utf8).write(to: fallback)
        let model = BatchRenamer(urls: [image, absent, fallback])
        defer { model.cancelPendingWork() }
        model.mode = .exifDate
        model.dateFormat = "YYYY-MM-DD"
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertEqual(model.previewRows.prefix(2).map(\.newName), ["2020-02-03-1.jpg", "nodate-2.jpg"])
        let fallbackRow = try XCTUnwrap(model.previewRows.last)
        XCTAssertEqual(fallbackRow.id, fallback)
        XCTAssertFalse(fallbackRow.newName.hasPrefix("nodate"))

        // If metadata were read again, both date prefixes would change.
        try makeImage(at: image, date: "2024:05:06 07:08:09")
        try makeImage(at: absent, date: "2025:06:07 08:09:10")
        model.dateFormat = "YYMMDD"
        model.dateStartNumber = 9
        model.useSeparator = false
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertEqual(model.previewRows.prefix(2).map(\.newName), ["20020309.jpg", "nodate10.jpg"])
        XCTAssertFalse(model.isLoadingDates)
    }

    @MainActor
    func testCyclicRenamesPreserveContentsAndSourceOrder() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("1.txt")
        let second = root.appendingPathComponent("2.txt")
        try Data("A".utf8).write(to: first)
        try Data("B".utf8).write(to: second)
        let model = BatchRenamer(urls: [second, first])
        defer { model.cancelPendingWork() }
        model.mode = .sequence
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertTrue(model.canApply)
        let result = await model.apply()
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.renamed.map(\.from), [second, first])
        XCTAssertEqual(result.renamed.map(\.to), [first, second])
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "B")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "A")
    }

    @MainActor
    func testCollisionValidationAndApplyTimeRevalidation() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("1.txt")
        let second = root.appendingPathComponent("2.txt")
        try Data("A".utf8).write(to: first)
        try Data("B".utf8).write(to: second)
        let model = BatchRenamer(urls: [first, second])
        defer { model.cancelPendingWork() }
        model.useRegex = true
        model.find = "^.*$"
        model.replacement = "same"
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertEqual(model.previewRows.map(\.error), ["Duplicate target", "Duplicate target"])
        XCTAssertFalse(model.canApply)

        model.mode = .sequence
        model.prefix = "bad/"
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertEqual(model.previewRows.map(\.error), ["Invalid name", "Invalid name"])

        model.prefix = "collision"
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertTrue(model.canApply)
        let occupied = root.appendingPathComponent("collision1.txt")
        try Data("existing".utf8).write(to: occupied)
        let result = await model.apply()
        XCTAssertTrue(result.renamed.isEmpty)
        XCTAssertTrue(result.errors.contains { $0.contains("Already exists") })
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "B")
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "existing")
    }

    @MainActor
    func testDebounceLatestGenerationAndDismissalCancellation() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = (0..<30_000).map { root.appendingPathComponent("source\($0).txt") }
        let model = BatchRenamer(urls: urls)
        defer { model.cancelPendingWork() }
        model.mode = .sequence
        let start = ContinuousClock.now
        for index in 0..<100 {
            model.prefix = "edit\(index)-"
            model.requestPreview()
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertTrue(model.previewRows.isEmpty, "Keystrokes must not synchronously compute previews")
        XCTAssertFalse(model.canApply)
        try await Task.sleep(for: .milliseconds(210))
        model.urls = [root.appendingPathComponent("latest.txt")]
        model.prefix = "latest-"
        model.requestPreview()
        try await waitForPreview(model)
        XCTAssertEqual(model.previewRows.map(\.newName), ["latest-1.txt"])

        model.prefix = "dismissed-"
        model.requestPreview()
        model.cancelPendingWork()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.previewRows.map(\.newName), ["latest-1.txt"])
        XCTAssertFalse(model.canApply)
    }

    @MainActor
    func testDateFormattingEditsShareLoadingAndModeChangeCancelsIt() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BatchRenamer(urls: (0..<30_000).map {
            root.appendingPathComponent("source\($0).txt")
        })
        defer { model.cancelPendingWork() }
        model.mode = .exifDate
        model.requestPreview()
        try await waitForDateLoading(model)
        for format in ["yyyy", "MM", "dd"] {
            model.dateFormat = format
            model.requestPreview()
            XCTAssertTrue(model.isLoadingDates, "Formatting edits must not restart the shared date task")
            XCTAssertFalse(model.canApply)
        }
        model.mode = .sequence
        model.urls = [root.appendingPathComponent("latest.txt")]
        model.prefix = "after-date-"
        model.requestPreview()
        XCTAssertFalse(model.isLoadingDates)
        try await waitForPreview(model)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.previewRows.map(\.newName), ["after-date-1.txt"])
    }

    @MainActor
    func testDateFilterChangeAndDismissalCancelOwnedLoad() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BatchRenamer(urls: (0..<30_000).map {
            root.appendingPathComponent("source\($0).txt")
        })
        defer { model.cancelPendingWork() }
        model.mode = .exifDate
        model.requestPreview()
        try await waitForDateLoading(model)
        model.extensionFilter = "jpg"
        model.requestPreview()
        XCTAssertFalse(model.isLoadingDates, "Changing the date scope cancels its old worker immediately")
        try await waitForPreview(model)
        XCTAssertTrue(model.previewRows.isEmpty)
        XCTAssertFalse(model.canApply)

        model.extensionFilter = ""
        model.requestPreview()
        try await waitForDateLoading(model)
        model.cancelPendingWork()
        XCTAssertFalse(model.isLoadingDates)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(model.previewRows.isEmpty)
        XCTAssertFalse(model.canApply)
    }

    @MainActor
    func testCancelledApplyDoesNotStageSources() async throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let model = BatchRenamer(urls: [source])
        defer { model.cancelPendingWork() }
        model.mode = .sequence
        model.requestPreview()
        try await waitForPreview(model)
        let task = Task { await model.apply() }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.renamed.isEmpty)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("1.txt").path))
    }

    private enum ProbeError: Error { case previewTimedOut, dateLoadDidNotStart }

    @MainActor
    private func waitForDateLoading(_ model: BatchRenamer) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.isLoadingDates {
            guard model.isPreviewLoading, ContinuousClock.now < deadline else {
                throw ProbeError.dateLoadDidNotStart
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor
    private func waitForPreview(_ model: BatchRenamer) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while model.isPreviewLoading {
            guard ContinuousClock.now < deadline else { throw ProbeError.previewTimedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeFixtureDirectory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".batch-rename-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func makeImage(at url: URL, date: String) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data([UInt8(0), 0, 0, 255]) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
