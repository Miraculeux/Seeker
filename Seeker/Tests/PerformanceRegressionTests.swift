import Foundation
import XCTest
@testable import Seeker

final class PerformanceRegressionTests: XCTestCase, @unchecked Sendable {
    func testBackgroundWorkDoesNotRunOnMainThread() async throws {
        let isMain = try await Task { @MainActor in
            try await BackgroundWork.run { Thread.isMainThread }
        }.value
        XCTAssertFalse(isMain)
    }

    func testCancellationReachesBackgroundWorker() async throws {
        let started = expectation(description: "Worker started")
        let finished = expectation(description: "Worker stopped")
        let task = Task {
            defer { finished.fulfill() }
            return try await BackgroundWork.run { () throws -> Int in
                started.fulfill()
                while true {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await fulfillment(of: [finished], timeout: 5)
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not return a result")
        } catch is CancellationError {
        }
    }

    func testNaturalSortKeepsFoldersFirstInBothDirections() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let names = ["file10.txt", "file2.txt", "file1.txt"]
        for name in names { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let items = names.map { FileItem(url: root.appendingPathComponent($0)) } + [FileItem(url: directory)]

        let ascending = try FileExplorerViewModel.sortItems(items, order: .name, ascending: true)
        let descending = try FileExplorerViewModel.sortItems(items, order: .name, ascending: false)
        XCTAssertEqual(ascending.map(\.name), ["folder", "file1.txt", "file2.txt", "file10.txt"])
        XCTAssertEqual(descending.map(\.name), ["folder", "file10.txt", "file2.txt", "file1.txt"])
        let bySize = try FileExplorerViewModel.sortItems(items, order: .size, ascending: true)
        XCTAssertEqual(bySize.first?.name, "folder")
        XCTAssertEqual(bySize.last?.name, "file10.txt")
    }

    @MainActor
    func testPlannedCopyPreservesPayload() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let payload = Data(repeating: 0x5A, count: 256 * 1024)
        try payload.write(to: source)
        let completed = expectation(description: "Copy completed")
        let op = try XCTUnwrap(FileOperationManager.shared.startPlannedCopy([
            .init(source: source, destination: destination, replace: false)
        ]) { _ in completed.fulfill() })
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertNil(op.error)
        XCTAssertEqual(op.completedDestinations, [destination])
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    @MainActor
    func testCancelledCopyDoesNotStartTransfer() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try Data([1, 2, 3]).write(to: source)
        let completed = expectation(description: "Cancelled operation completed")
        let op = try XCTUnwrap(FileOperationManager.shared.startPlannedCopy([
            .init(source: source, destination: destination, replace: false)
        ]) { _ in completed.fulfill() })
        op.cancel()
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertTrue(op.isFinished)
        XCTAssertTrue(op.completedDestinations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testNavigationRejectsPreviousDirectoryResults() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        for index in 0..<100 {
            try Data().write(to: first.appendingPathComponent("old-\(index)"))
        }
        try Data().write(to: second.appendingPathComponent("current"))
        let model = FileExplorerViewModel(url: first)
        defer { model.cancelLoading() }
        model.navigateTo(second)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.files.map(\.name) != ["current"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.currentURL, second)
        XCTAssertEqual(model.files.map(\.name), ["current"])
    }

    @MainActor
    func testBackgroundCompressionPreservesMultipleFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        let payload = Data(repeating: 0x42, count: 32 * 1024)
        try payload.write(to: first)
        try payload.write(to: second)
        let model = FileExplorerViewModel(url: root)
        defer { model.cancelLoading() }
        model.cancelLoading()
        model.files = [FileItem(url: first), FileItem(url: second)]
        model.selectedFileIDs = Set(model.files.map(\.id))
        model.compressSelected()
        XCTAssertNotNil(model.fileMutationStatus)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.fileMutationStatus != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.fileMutationStatus)
        XCTAssertNil(model.errorMessage)
        let archive = root.appendingPathComponent("Archive.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let extracted = root.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let exitCode = try await BackgroundWork.run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, extracted.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("first.txt")), payload)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("second.txt")), payload)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeekerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
