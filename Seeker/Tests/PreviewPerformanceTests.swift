import Foundation
import XCTest
@testable import Seeker

@MainActor
final class PreviewPerformanceTests: XCTestCase {
    private func makeFixtureDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".preview-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testTextPreviewReadsOnlyByteLimitOffMain() async throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: 192 * 1024).write(to: file)

        let (result, ranOnMainThread) = try await BackgroundWork.run {
            (try TextPreviewPanelController.loadText(from: file, limit: 128 * 1024), Thread.isMainThread)
        }

        XCTAssertFalse(ranOnMainThread)
        XCTAssertEqual(result.text, String(repeating: "A", count: 128 * 1024))
        XCTAssertEqual(result.totalBytes, 192 * 1024)
        XCTAssertTrue(result.truncated)
    }

    func testTextPreviewPreservesUTF8AndDropsIncompleteTrailingCharacter() async throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("utf8.txt")
        try Data("hello € world".utf8).write(to: file)

        let (full, truncated) = try await BackgroundWork.run {
            (
                try TextPreviewPanelController.loadText(from: file, limit: 1024),
                try TextPreviewPanelController.loadText(from: file, limit: 8)
            )
        }

        XCTAssertEqual(full.text, "hello € world")
        XCTAssertFalse(full.truncated)
        XCTAssertEqual(truncated.text, "hello ")
        XCTAssertEqual(truncated.totalBytes, 15)
        XCTAssertTrue(truncated.truncated)
    }

    func testTextPreviewPreservesEmptyDirectoryAndMissingFileMessages() async throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let emptyFile = directory.appendingPathComponent("empty.txt")
        let missingFile = directory.appendingPathComponent("missing.txt")
        try Data().write(to: emptyFile)

        let (empty, folder, missing) = try await BackgroundWork.run {
            (
                try TextPreviewPanelController.loadText(from: emptyFile, limit: 1024),
                try TextPreviewPanelController.loadText(from: directory, limit: 1024),
                try TextPreviewPanelController.loadText(from: missingFile, limit: 1024)
            )
        }

        XCTAssertEqual(empty.text, "〔空文件〕")
        XCTAssertEqual(folder.text, "〔这是一个文件夹，无法作为文本预览〕")
        XCTAssertEqual(missing.text, "〔无法打开文件：missing.txt〕")
        XCTAssertFalse(empty.truncated)
        XCTAssertEqual(empty.totalBytes, 0)
    }

    func testTextReaderRejectsCancellationBeforeOpeningFile() async throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingFile = directory.appendingPathComponent("must-not-open.txt")
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let worker = Task.detached {
            for await _ in gate {}
            return try TextPreviewPanelController.loadText(from: missingFile, limit: 1024)
        }

        worker.cancel()
        continuation.finish()

        do {
            _ = try await worker.value
            XCTFail("Cancellation should prevent even the missing-file lookup")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDirectorySizeCountsNestedSyntheticFilesOffMain() async throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let files = [
            directory.appendingPathComponent("first.bin"),
            nested.appendingPathComponent("second.bin")
        ]
        for file in files {
            try Data(repeating: 65, count: 8192).write(to: file)
        }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        let expected = try files.reduce(Int64(0)) { total, file in
            let values = try file.resourceValues(forKeys: keys)
            return total + Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }

        let (size, ranOnMainThread) = try await BackgroundWork.run(priority: .utility) {
            (FileInfoView.directorySize(at: directory), Thread.isMainThread)
        }

        XCTAssertFalse(ranOnMainThread)
        XCTAssertEqual(size, expected)
    }

    func testDirectorySizeChecksWorkerCancellationBeforeEnumeration() async throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let worker = Task.detached {
            for await _ in gate {}
            return FileInfoView.directorySize(at: directory)
        }

        worker.cancel()
        continuation.finish()

        let result = await worker.value
        XCTAssertEqual(result, -1)
    }
}
