import CryptoKit
import Foundation
import XCTest
@testable import Seeker

@MainActor
final class SearchPerformanceTests: XCTestCase {
    func testStreamingHashMatchesWholeBufferAndRejectsReadErrors() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data(repeating: 0x61, count: 2 * 1024 * 1024)
        let file = try fixture.write("payload.bin", data: payload)

        XCTAssertEqual(XXHash3.hashFile(at: file, chunkSize: 4096), XXHash3.hash(payload))
        XCTAssertNil(XXHash3.hashFile(at: file, chunkSize: 0))
        XCTAssertNil(XXHash3.hashFile(at: fixture.root), "A read error must not produce a partial digest")
        XCTAssertNil(XXHash3.hashFile(at: fixture.root.appendingPathComponent("missing")))
    }

    func testCancelledStreamingHashDoesNotPublishPartialDigest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = try fixture.write("payload.bin", data: Data(repeating: 0x61, count: 16 * 1024 * 1024))
        // Tiny reads keep this synthetic worker active without requiring a huge file.
        let task = Task.detached { XXHash3.hashFile(at: file, chunkSize: 1) }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()

        let digest = await task.value
        XCTAssertNil(digest, "Cancellation must stop the chunk loop, not publish an EOF/partial digest")
    }

    func testChecksumMatchesSHA256AndSurfacesReadFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data(repeating: 0x61, count: 2 * 1024 * 1024)
        let file = try fixture.write("payload.bin", data: payload)
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let checksum = try await SemanticModelManager.checksum(of: file)
        XCTAssertEqual(checksum, expected)
        do {
            _ = try await SemanticModelManager.checksum(of: fixture.root)
            XCTFail("Checksum read failures must be thrown, not converted to a digest")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testPreCancelledChecksumDoesNotPublishResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = try fixture.write("payload.bin", data: Data("payload".utf8))
        let task = Task { try await SemanticModelManager.checksum(of: file) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled verification must not publish a checksum")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testNameSearchPublishesOnlyReplacementQuery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try fixture.tree(count: 256)
        let searcher = FileSearcher(root: tree)
        defer { searcher.cancel() }
        searcher.query = "item"
        searcher.search()
        searcher.cancel()
        searcher.query = "item-255.txt"
        searcher.search()

        try await waitUntil { if case .done = searcher.status { return true }; return false }
        XCTAssertEqual(searcher.results.map(\.name), ["item-255.txt"])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(searcher.results.map(\.name), ["item-255.txt"])

        searcher.query = "item"
        searcher.search()
        searcher.query = ""
        searcher.search()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(searcher.status, .idle)
        XCTAssertTrue(searcher.results.isEmpty)
    }

    func testRecursiveComparisonRejectsCancelledGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try fixture.tree(count: 256)
        let empty = try fixture.directory("empty")
        let comparer = DirectoryComparer(dirA: tree, dirB: empty)
        defer { comparer.cancel() }
        comparer.recursive = true
        comparer.compare()
        try await waitUntil { comparer.status == .done }
        XCTAssertEqual(comparer.onlyInA.count, 256)
        XCTAssertTrue(comparer.onlyInB.isEmpty)

        comparer.compare()
        comparer.cancel()
        comparer.dirA = empty
        comparer.compare()
        try await waitUntil { comparer.status == .done }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(comparer.onlyInA.isEmpty)
        XCTAssertTrue(comparer.onlyInB.isEmpty)
    }

    func testDuplicateScanCancellationCannotOverwriteNewScan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try fixture.tree(count: 256)
        let empty = try fixture.directory("empty")
        let finder = DuplicateFinder()
        defer { finder.cancel() }
        finder.minimumFileSize = 1
        finder.scan(root: tree)
        finder.cancel()
        finder.scan(root: empty)
        try await waitUntil { finder.status == .done }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(finder.status, .done)
        XCTAssertTrue(finder.groups.isEmpty)

        finder.scan(root: tree)
        try await waitUntil { finder.status == .done }
        XCTAssertEqual(finder.groups.count, 1)
        XCTAssertEqual(finder.groups.first?.urls.count, 256)
    }

    func testSyncAnalysisCancellationPreservesReplacementDirection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try fixture.tree(count: 256)
        let empty = try fixture.directory("empty")
        let syncer = FolderSyncer(rootA: empty, rootB: tree)
        defer { syncer.cancel() }
        syncer.direction = .mirror
        syncer.analyze()
        try await waitUntil { syncer.status == .ready }
        XCTAssertEqual(syncer.actions.count, 256)
        XCTAssertTrue(syncer.actions.allSatisfy { $0.kind == .deleteB })

        syncer.analyze()
        syncer.cancel()
        syncer.direction = .update
        syncer.analyze()
        try await waitUntil { syncer.status == .ready }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(syncer.status, .ready)
        XCTAssertTrue(syncer.actions.isEmpty)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum ProbeError: Error {
        case timedOut
    }

    private struct Fixture {
        let root: URL

        init() throws {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            root = repository.appendingPathComponent(
                ".build/search-performance-fixtures/\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ name: String, data: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func tree(count: Int) throws -> URL {
            let url = try directory("tree")
            for index in 0..<count {
                try Data("identical".utf8).write(to: url.appendingPathComponent("item-\(index).txt"))
            }
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
