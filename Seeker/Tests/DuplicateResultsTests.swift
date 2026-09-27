import Foundation
import XCTest
@testable import Seeker

final class DuplicateResultsTests: XCTestCase {
    func testGroupsFilesFromDifferentContentGroupsIntoTheirContainingDirectory() {
        let a1 = URL(fileURLWithPath: "/A/one.txt")
        let a2 = URL(fileURLWithPath: "/A/two.txt")
        let b1 = URL(fileURLWithPath: "/B/one-copy.txt")
        let b2 = URL(fileURLWithPath: "/B/two-copy.txt")
        let groups = [
            DuplicateFinder.Group(fileSize: 10, urls: [a1, b1]),
            DuplicateFinder.Group(fileSize: 20, urls: [a2, b2]),
        ]
        let directories = DuplicateResultDirectory.grouped(groups)
        XCTAssertEqual(directories.map(\.url.path), ["/A", "/B"])
        XCTAssertEqual(directories[0].files.map(\.url), [a1, a2])
        XCTAssertEqual(directories[1].files.map(\.url), [b1, b2])
        XCTAssertEqual(directories[0].files.map(\.fileSize), [10, 20])
        XCTAssertEqual(directories[1].files[1].copies, [a2, b2])
    }

    func testBothLevelsUseNaturalNameOrderRatherThanSizeOrFullPath() {
        let urls = [
            "/a/Folder10/file10.txt", "/z/Folder2/file10.txt",
            "/z/Folder2/file2.txt", "/a/Folder10/file2.txt",
        ].map { URL(fileURLWithPath: $0) }
        let directories = DuplicateResultDirectory.grouped([
            DuplicateFinder.Group(fileSize: 100, urls: urls)
        ])
        XCTAssertEqual(directories.map(\.name), ["Folder2", "Folder10"])
        for directory in directories {
            XCTAssertEqual(directory.files.map(\.url.lastPathComponent), ["file2.txt", "file10.txt"])
        }
    }

    func testSameNamedDirectoriesRemainSeparateWithStablePathTieBreak() {
        let urls = ["/z/Same/file.txt", "/a/Same/file.txt"].map { URL(fileURLWithPath: $0) }
        let directories = DuplicateResultDirectory.grouped([
            DuplicateFinder.Group(fileSize: 10, urls: urls)
        ])
        XCTAssertEqual(directories.map(\.url.path), ["/a/Same", "/z/Same"])
        XCTAssertEqual(Set(directories.map(\.id)).count, 2)
    }

    func testDisplaySortingPreservesSuggestedKeepAndCopyRelationships() {
        let keep = URL(fileURLWithPath: "/Z/file10.txt")
        let copy = URL(fileURLWithPath: "/A/file2.txt")
        let group = DuplicateFinder.Group(fileSize: 50, urls: [keep, copy])
        let directories = DuplicateResultDirectory.grouped([group])
        let displayedCopy = directories[0].files[0]
        let displayedKeep = directories[1].files[0]
        XCTAssertFalse(displayedCopy.isSuggestedKeep)
        XCTAssertTrue(displayedKeep.isSuggestedKeep)
        XCTAssertEqual(displayedCopy.suggestedKeep, keep)
        XCTAssertEqual(displayedCopy.copies, [keep, copy])
        XCTAssertEqual(group.urls, [keep, copy])
        XCTAssertEqual(group.reclaimableBytes, 50)
    }

    func testRegroupingAfterDeletionKeepsDirectoryIdentityAndDropsAbsentRows() {
        let a = URL(fileURLWithPath: "/A/a.txt")
        let b = URL(fileURLWithPath: "/B/b.txt")
        let c = URL(fileURLWithPath: "/B/c.txt")
        let initial = DuplicateResultDirectory.grouped([
            DuplicateFinder.Group(fileSize: 10, urls: [a, b, c])
        ])
        let updated = DuplicateResultDirectory.grouped([
            DuplicateFinder.Group(fileSize: 10, urls: [a, c])
        ])
        XCTAssertEqual(initial.map(\.id), updated.map(\.id))
        XCTAssertEqual(updated.flatMap { $0.files.map(\.url) }, [a, c])
        XCTAssertTrue(DuplicateResultDirectory.grouped([]).isEmpty)
    }

    func testBadgesDescribeContentGroupsNotMatchingNamesOrSizes() {
        let groupA = DuplicateFinder.Group(fileSize: 100, urls: [
            URL(fileURLWithPath: "/A/cover.jpg"), URL(fileURLWithPath: "/B/renamed.jpg"),
        ])
        let groupB = DuplicateFinder.Group(fileSize: 100, urls: [
            URL(fileURLWithPath: "/C/cover.jpg"), URL(fileURLWithPath: "/D/cover.jpg"),
        ])
        let files = DuplicateResultDirectory.grouped([groupB, groupA]).flatMap(\.files)
        let a = files.filter { $0.groupID == groupA.id }
        let b = files.filter { $0.groupID == groupB.id }
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(Set(a.map(\.groupNumber)), [1])
        XCTAssertEqual(Set(b.map(\.groupNumber)), [2])
        XCTAssertEqual(a.first?.groupLabel, "Group 01")
        XCTAssertEqual(b.first?.groupLabel, "Group 02")
        XCTAssertEqual(a.first?.copies, groupA.urls)
        XCTAssertEqual(b.first?.copies, groupB.urls)
    }

    func testNumberingIsIndependentOfGroupAndMemberOrder() {
        let a = URL(fileURLWithPath: "/A/file2")
        let b = URL(fileURLWithPath: "/B/file10")
        let c = URL(fileURLWithPath: "/C/file20")
        let d = URL(fileURLWithPath: "/D/file30")
        let first = DuplicateFinder.Group(fileSize: 200, urls: [b, a])
        let second = DuplicateFinder.Group(fileSize: 100, urls: [d, c])
        let original = DuplicateResultDirectory.grouped([second, first]).flatMap(\.files)
        let reordered = DuplicateResultDirectory.grouped([
            DuplicateFinder.Group(id: first.id, fileSize: 200, urls: [a, b]),
            DuplicateFinder.Group(id: second.id, fileSize: 100, urls: [c, d]),
        ]).flatMap(\.files)
        XCTAssertEqual(original.map(\.groupNumber), reordered.map(\.groupNumber))
        XCTAssertEqual(original.first?.suggestedKeep, b)
    }

    func testDeletionPreservesGroupIdentityAndNumberAndRefreshesCopies() throws {
        let a = URL(fileURLWithPath: "/A/a")
        let b = URL(fileURLWithPath: "/B/b")
        let c = URL(fileURLWithPath: "/C/c")
        let d = URL(fileURLWithPath: "/D/d")
        let e = URL(fileURLWithPath: "/E/e")
        let first = DuplicateFinder.Group(fileSize: 100, urls: [a, b])
        let second = DuplicateFinder.Group(fileSize: 200, urls: [c, d, e])
        let initial = DuplicateResultDirectory.grouped([first, second]).flatMap(\.files)
        var numbers: [UUID: Int] = [:]
        for file in initial { numbers[file.groupID] = file.groupNumber }
        XCTAssertNil(first.removing([a]))
        let remaining = try XCTUnwrap(second.removing([c]))
        XCTAssertEqual(remaining.id, second.id)
        let refreshed = DuplicateResultDirectory.grouped([remaining], previousNumbers: numbers).flatMap(\.files)
        XCTAssertEqual(refreshed.map(\.groupNumber), [2, 2])
        XCTAssertEqual(refreshed.first?.copies, [d, e])
        XCTAssertEqual(refreshed.first?.suggestedKeep, d)
        XCTAssertEqual(refreshed.first?.fileSize, 200)
        XCTAssertNil(remaining.removing([d, e]))
    }
}
