import Foundation
import XCTest
@testable import Seeker

@MainActor
final class DirectoryComparerWorkflowTests: XCTestCase {
    private func compared(_ fixture: WorkflowFixture, recursive: Bool = false,
                          hidden: Bool = false) async throws -> DirectoryComparer {
        let comparer = DirectoryComparer(dirA: fixture.url("A"), dirB: fixture.url("B"))
        comparer.recursive = recursive
        comparer.includeHidden = hidden
        comparer.compare()
        do { try await waitForWorkflow { comparer.status == .done } }
        catch { comparer.cancel(); throw error }
        return comparer
    }

    func testTopLevelComparesCaseInsensitiveNamesNotContentsOrTypes() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.write("A/REPORT.txt", "short")
        try fixture.write("B/report.TXT", "different and longer")
        try fixture.directory("A/same-name")
        try fixture.write("B/same-name", "a file, not a folder")
        try fixture.write("A/zebra", "z")
        try fixture.write("A/Alpha", "alpha")
        try fixture.directory("B/only-folder")
        let comparer = try await compared(fixture)
        defer { comparer.cancel() }
        XCTAssertEqual(comparer.onlyInA.map(\.relativePath), ["Alpha", "zebra"])
        XCTAssertEqual(comparer.onlyInB.map(\.relativePath), ["only-folder"])
        let file = try XCTUnwrap(comparer.onlyInA.first)
        XCTAssertEqual(file.id, file.url.absoluteString)
        XCTAssertEqual(file.fileSize, 5)
        XCTAssertFalse(file.isDirectory)
        XCTAssertFalse(file.formattedSize.isEmpty)
        let folder = try XCTUnwrap(comparer.onlyInB.first)
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.formattedSize, "")
    }

    func testRecursiveComparisonUsesRelativePathsAndOmitsEmptyDirectories() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.write("A/left/same.txt", "left")
        try fixture.write("B/right/same.txt", "right")
        try fixture.write("A/SHARED/File.txt", "A")
        try fixture.write("B/shared/file.TXT", "entirely different")
        try fixture.directory("A/empty")
        try fixture.directory("B/another-empty")
        let comparer = try await compared(fixture, recursive: true)
        defer { comparer.cancel() }
        XCTAssertEqual(comparer.onlyInA.map(\.relativePath), ["left/same.txt"])
        XCTAssertEqual(comparer.onlyInB.map(\.relativePath), ["right/same.txt"])
        XCTAssertEqual(comparer.onlyInA.map(\.name), ["same.txt"])
        XCTAssertEqual(comparer.onlyInA.map(\.fileSize), [4])
        XCTAssertTrue((comparer.onlyInA + comparer.onlyInB).allSatisfy { !$0.isDirectory })
    }

    func testTopLevelAndRecursiveModesExposeDifferentTreeDifferences() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.write("A/shared/a-only", "A")
        try fixture.write("B/shared/b-only", "B")
        let topLevel = try await compared(fixture)
        let recursive = try await compared(fixture, recursive: true)
        defer { topLevel.cancel(); recursive.cancel() }
        XCTAssertTrue(topLevel.onlyInA.isEmpty)
        XCTAssertTrue(topLevel.onlyInB.isEmpty)
        XCTAssertEqual(recursive.onlyInA.map(\.relativePath), ["shared/a-only"])
        XCTAssertEqual(recursive.onlyInB.map(\.relativePath), ["shared/b-only"])
    }

    func testHiddenFilesAndHiddenSubtreesRequireOptInInBothModes() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.directory("B")
        try fixture.write("A/.secret", "secret")
        try fixture.write("A/.folder/child", "child")
        try fixture.write("A/visible", "visible")
        for recursive in [false, true] {
            let visible = try await compared(fixture, recursive: recursive)
            let all = try await compared(fixture, recursive: recursive, hidden: true)
            XCTAssertEqual(visible.onlyInA.map(\.relativePath), ["visible"])
            XCTAssertEqual(Set(all.onlyInA.map(\.relativePath)),
                           recursive ? [".secret", ".folder/child", "visible"] : [".secret", ".folder", "visible"])
            XCTAssertTrue(all.onlyInB.isEmpty)
            visible.cancel()
            all.cancel()
        }
    }

    func testRemoveNormalizesURLAndOnlyChangesResultListsNotFilesystem() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.write("A/remove-me", "preserve")
        try fixture.write("A/keep-me", "keep")
        try fixture.write("B/other", "other")
        let comparer = try await compared(fixture)
        defer { comparer.cancel() }
        comparer.remove(fixture.url("A/./remove-me"))
        comparer.remove(fixture.url("B/./other"))
        comparer.remove(fixture.url("A/nonexistent"))
        XCTAssertEqual(comparer.onlyInA.map(\.name), ["keep-me"])
        XCTAssertTrue(comparer.onlyInB.isEmpty)
        XCTAssertEqual(comparer.status, .done)
        XCTAssertEqual(try fixture.contents("A/remove-me"), "preserve")
        XCTAssertEqual(try fixture.contents("B/other"), "other")
    }

    func testCancelledComparisonCanBeReplacedWithoutPublishingOldRoots() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.write("A/old", "old")
        try fixture.directory("B")
        try fixture.write("replacement/current", "current")
        let comparer = DirectoryComparer(dirA: fixture.url("A"), dirB: fixture.url("B"))
        defer { comparer.cancel() }
        comparer.compare()
        comparer.cancel()
        XCTAssertTrue(comparer.onlyInA.isEmpty)
        XCTAssertTrue(comparer.onlyInB.isEmpty)
        comparer.dirA = fixture.url("replacement")
        comparer.compare()
        try await waitForWorkflow { comparer.status == .done }
        XCTAssertEqual(comparer.onlyInA.map(\.relativePath), ["current"])
        XCTAssertEqual(comparer.onlyInA.map(\.url), [fixture.url("replacement/current")])
        XCTAssertTrue(comparer.onlyInB.isEmpty)
    }
}
