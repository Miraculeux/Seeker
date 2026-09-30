import Foundation
import XCTest
@testable import Seeker

@MainActor
final class ExplorerSelectionTests: XCTestCase {
    func testPlainClickReplacesSelectionAndAnchor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.selectedFileIDs = Set(fixture.items.map(\.id))

        model.handleFileClick(fixture.items[1], command: false, shift: false)

        XCTAssertEqual(model.selectedFileIDs, [fixture.items[1].id])
        XCTAssertEqual(model.selectionAnchor, fixture.items[1])
        XCTAssertEqual(model.selectedFile, fixture.items[1])
    }

    func testCommandClickTogglesItemsAndClearsAnchorAfterLastRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.handleFileClick(fixture.items[0], command: false, shift: false)
        model.handleFileClick(fixture.items[2], command: true, shift: false)
        XCTAssertEqual(model.selectedFileIDs, [fixture.items[0].id, fixture.items[2].id])

        model.handleFileClick(fixture.items[2], command: true, shift: false)
        XCTAssertEqual(model.selectedFileIDs, [fixture.items[0].id])
        XCTAssertEqual(model.selectionAnchor, fixture.items[0])
        model.handleFileClick(fixture.items[0], command: true, shift: false)
        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        XCTAssertNil(model.selectionAnchor)
        XCTAssertNil(model.selectedFile)
    }

    func testShiftClickSelectsContiguousRangeInBothDirectionsWithoutMovingAnchor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.handleFileClick(fixture.items[1], command: false, shift: false)
        model.handleFileClick(fixture.items[3], command: false, shift: true)
        XCTAssertEqual(model.selectedFileIDs, Set(fixture.items[1...3].map(\.id)))
        XCTAssertEqual(model.selectionAnchor, fixture.items[1])

        model.handleFileClick(fixture.items[0], command: false, shift: true)
        XCTAssertEqual(model.selectedFileIDs, Set(fixture.items[0...1].map(\.id)))
        XCTAssertEqual(model.selectionAnchor, fixture.items[1])
    }

    func testShiftClickWithoutAnchorActsAsSingleSelection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.handleFileClick(fixture.items[2], command: false, shift: true)

        XCTAssertEqual(model.selectedFileIDs, [fixture.items[2].id])
        XCTAssertEqual(model.selectionAnchor, fixture.items[2])
    }

    func testShiftClickAfterAnchorDisappearsDoesNotSelectStaleRange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.handleFileClick(fixture.items[0], command: false, shift: false)
        model.files = Array(fixture.items.dropFirst())
        model.handleFileClick(fixture.items[3], command: false, shift: true)

        XCTAssertEqual(model.selectedFileIDs, [fixture.items[3].id])
        XCTAssertEqual(model.selectionAnchor, fixture.items[3])
    }

    func testSelectionCacheInvalidatesWhenIDsOrListingChange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.selectedFileIDs = [fixture.items[0].id]
        XCTAssertEqual(model.selectedFiles, [fixture.items[0]])
        XCTAssertEqual(model.selectedFiles, [fixture.items[0]])

        model.selectedFileIDs = [fixture.items[1].id]
        XCTAssertEqual(model.selectedFiles, [fixture.items[1]])
        model.files = [fixture.items[2]]
        XCTAssertTrue(model.selectedFiles.isEmpty)
        XCTAssertNil(model.selectedFile)
    }

    func testSelectAllUsesDisplayedListingRatherThanInvisibleItems() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.files = [fixture.items[1], fixture.items[3]]
        model.selectAll()

        XCTAssertEqual(model.selectedFileIDs, [fixture.items[1].id, fixture.items[3].id])
        XCTAssertEqual(model.selectedFiles, [fixture.items[1], fixture.items[3]])
        XCTAssertEqual(model.selectionAnchor, fixture.items[1])
    }

    func testRepeatedNavigationDoesNotDuplicateHistoryAndNewBranchDiscardsForwardHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("first", isDirectory: true)
        let second = fixture.root.appendingPathComponent("second", isDirectory: true)
        let replacement = fixture.root.appendingPathComponent("replacement", isDirectory: true)
        for directory in [first, second, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let model = fixture.model()
        defer { model.cancelLoading() }
        model.navigateTo(first)
        model.navigateTo(first)
        model.navigateTo(second)
        XCTAssertEqual(model.pathHistory, [fixture.root, first, second])
        XCTAssertFalse(model.canGoForward)

        model.goBack()
        XCTAssertEqual(model.currentURL, first)
        XCTAssertTrue(model.canGoForward)
        model.navigateTo(replacement)
        XCTAssertEqual(model.pathHistory, [fixture.root, first, replacement])
        XCTAssertFalse(model.canGoForward)
    }

    func testNavigationClearsSelectionFilterAndTreeExpansion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let model = fixture.model()
        defer { model.cancelLoading() }
        model.handleFileClick(fixture.items[0], command: false, shift: false)
        model.searchText = "old filter"
        model.isSearching = true
        model.expandedDirectoryIDs = ["old-directory"]
        model.loadingDirectoryIDs = ["old-directory"]
        model.navigateTo(destination)

        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        XCTAssertNil(model.selectionAnchor)
        XCTAssertEqual(model.searchText, "")
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.expandedDirectoryIDs.isEmpty)
        XCTAssertTrue(model.loadingDirectoryIDs.isEmpty)
    }

    private struct Fixture {
        let root: URL
        let items: [FileItem]

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Seeker-selection-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let directory = root
            items = try (0..<4).map { index in
                let url = directory.appendingPathComponent("item-\(index).txt")
                try Data([UInt8(index)]).write(to: url)
                return FileItem(url: url)
            }
        }

        @MainActor
        func model() -> FileExplorerViewModel {
            let model = FileExplorerViewModel(url: root)
            model.cancelLoading()
            model.files = items
            return model
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
