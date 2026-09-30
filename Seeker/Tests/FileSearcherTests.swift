import Foundation
import XCTest
@testable import Seeker

@MainActor
final class FileSearcherTests: XCTestCase {
    func testHiddenFilesAndHiddenSubdirectoriesAreOptIn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("visible.txt", data: Data())
        _ = try fixture.write(".hidden.txt", data: Data())
        _ = try fixture.write(".concealed/nested.txt", data: Data())
        let searcher = FileSearcher(root: fixture.root)
        defer { searcher.cancel() }
        searcher.query = "*.txt"
        try await search(searcher)
        XCTAssertEqual(searcher.results.map(\.relativePath), ["visible.txt"])

        searcher.includeHidden = true
        try await search(searcher)
        XCTAssertEqual(
            Set(searcher.results.map(\.relativePath)),
            ["visible.txt", ".hidden.txt", ".concealed/nested.txt"]
        )

        searcher.includeSubdirectories = false
        try await search(searcher)
        XCTAssertEqual(Set(searcher.results.map(\.relativePath)), ["visible.txt", ".hidden.txt"])
    }

    func testResultsContainRelativePathsDirectoryFlagsAndExactFileSizes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data(repeating: 0x42, count: 1234)
        _ = try fixture.write("matched-folder/matched-file.bin", data: payload)
        let searcher = FileSearcher(root: fixture.root)
        defer { searcher.cancel() }
        searcher.query = "matched"
        try await search(searcher)

        XCTAssertEqual(searcher.status, .done(count: 2))
        XCTAssertEqual(searcher.results.map(\.relativePath), ["matched-folder", "matched-folder/matched-file.bin"])
        let folder = try XCTUnwrap(searcher.results.first { $0.isDirectory })
        XCTAssertEqual(folder.name, "matched-folder")
        XCTAssertEqual(folder.formattedSize, "")
        let file = try XCTUnwrap(searcher.results.first { !$0.isDirectory })
        XCTAssertEqual(file.fileSize, Int64(payload.count))
        XCTAssertEqual(file.id, file.url)
        XCTAssertEqual(
            file.formattedSize,
            ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .file)
        )
    }

    func testWhitespaceIsTrimmedAndNoMatchesReplacePreviousResults() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write("report.txt", data: Data())
        let searcher = FileSearcher(root: fixture.root)
        defer { searcher.cancel() }
        searcher.query = " \nreport\t "
        try await search(searcher)
        XCTAssertEqual(searcher.results.map(\.name), ["report.txt"])

        searcher.query = "no-such-match"
        try await search(searcher)
        XCTAssertEqual(searcher.status, .done(count: 0))
        XCTAssertTrue(searcher.results.isEmpty)

        searcher.query = " \n\t "
        searcher.search()
        XCTAssertEqual(searcher.status, .idle)
        XCTAssertTrue(searcher.results.isEmpty)
    }

    func testResultsAreSortedByRelativePathIndependentOfCreationOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for path in ["z/Report.txt", "B-report.txt", "a/Report.txt", "A-report.txt"] {
            _ = try fixture.write(path, data: Data())
        }
        let searcher = FileSearcher(root: fixture.root)
        defer { searcher.cancel() }
        searcher.query = "report"
        try await search(searcher)

        let expected = ["z/Report.txt", "B-report.txt", "a/Report.txt", "A-report.txt"]
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(searcher.results.map(\.relativePath), expected)
    }

    func testResultLimitCapsLargeMatchesWithoutDuplicates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 0..<5005 {
            _ = try fixture.write("match-\(index).txt", data: Data())
        }
        let searcher = FileSearcher(root: fixture.root)
        defer { searcher.cancel() }
        searcher.query = "match-*.txt"
        try await search(searcher)

        XCTAssertEqual(searcher.status, .done(count: 5000))
        XCTAssertEqual(searcher.results.count, 5000)
        XCTAssertEqual(Set(searcher.results.map(\.id)).count, 5000)
        XCTAssertTrue(searcher.results.allSatisfy { !$0.isDirectory && $0.fileSize == 0 })
    }

    private func search(_ searcher: FileSearcher) async throws {
        searcher.search()
        let deadline = ContinuousClock.now + .seconds(10)
        while searcher.status == .searching, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .done = searcher.status else {
            XCTFail("Search did not finish successfully: \(searcher.status)")
            throw CocoaError(.featureUnsupported)
        }
    }

    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Seeker-name-search-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ path: String, data: Data) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
