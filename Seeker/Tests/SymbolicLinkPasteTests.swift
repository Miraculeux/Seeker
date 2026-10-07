import AppKit
import Foundation
import XCTest
@testable import Seeker

@MainActor
final class SymbolicLinkPasteTests: XCTestCase {
    private final class FixtureExplorer: FileExplorerViewModel {
        override func navigateTo(_ url: URL) {
            currentURL = url
            selectedFileIDs = []
            selectionAnchor = nil
            files = []
        }
        override func loadFiles() {}
    }

    private var root: URL!
    private var savedClipboard: [URL] = []
    private var savedCut = false
    private var savedPasteboardItems: [NSPasteboardItem] = []

    override func setUp() async throws {
        savedPasteboardItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    saved.setData(data, forType: type)
                }
            }
            return saved
        }
        savedClipboard = FileExplorerViewModel.clipboard
        savedCut = FileExplorerViewModel.clipboardIsCut
        FileExplorerViewModel.clipboard = []
        FileExplorerViewModel.clipboardIsCut = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeekerLinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDown() async throws {
        FileExplorerViewModel.clipboard = savedClipboard
        FileExplorerViewModel.clipboardIsCut = savedCut
        NSPasteboard.general.clearContents()
        if !savedPasteboardItems.isEmpty {
            XCTAssertTrue(NSPasteboard.general.writeObjects(savedPasteboardItems))
        }
        try FileManager.default.removeItem(at: root)
    }

    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func file(_ name: String, contents: String = "original") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func select(_ urls: [URL], in model: FileExplorerViewModel) {
        model.files = urls.map { FileItem(url: $0) }
        model.selectedFileIDs = Set(model.files.map(\.id))
        model.selectionAnchor = model.files.first
    }

    func testCopyNavigateAndLinkPreservesSourceAndClipboard() throws {
        let source = try file("source/report.txt")
        let destination = try directory("destination")
        let model = FixtureExplorer(url: source.deletingLastPathComponent())
        select([source], in: model)
        model.copySelected()
        model.navigateTo(destination)

        XCTAssertTrue(model.canPasteSymbolicLink)
        model.pasteSymbolicLink()

        let link = destination.appendingPathComponent("report.txt")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), source.path)
        XCTAssertEqual(try Data(contentsOf: link), try Data(contentsOf: source))
        try Data("updated".utf8).write(to: source)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "updated")
        XCTAssertEqual(FileExplorerViewModel.clipboard, [source])
        XCTAssertFalse(FileExplorerViewModel.clipboardIsCut)
        XCTAssertTrue(model.canUndo)
        guard case .create(let created) = try XCTUnwrap(model.undoStack.last) else {
            return XCTFail("Link creation must use the existing create undo action")
        }
        XCTAssertEqual(created, link)
    }

    func testDirectoryLinkExposesOriginalChildrenWithoutCopying() throws {
        let source = try directory("source/folder")
        let child = try file("source/folder/child.txt")
        let destination = try directory("destination")
        let model = FixtureExplorer(url: destination)
        FileExplorerViewModel.clipboard = [source]

        model.pasteSymbolicLink()

        let link = destination.appendingPathComponent("folder")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), source.path)
        XCTAssertEqual(try Data(contentsOf: link.appendingPathComponent("child.txt")), try Data(contentsOf: child))
        try file("source/folder/new.txt", contents: "new child")
        XCTAssertEqual(try String(contentsOf: link.appendingPathComponent("new.txt"), encoding: .utf8), "new child")
    }

    func testSelectedFolderAndNestedFileFollowPasteDestinationRules() throws {
        let source = try file("source/report.txt")
        let destination = try directory("destination")
        let nested = try directory("destination/nested")
        let selectedFile = try file("destination/nested/existing.txt")
        let model = FixtureExplorer(url: destination)
        FileExplorerViewModel.clipboard = [source]

        select([nested], in: model)
        model.pasteSymbolicLink()
        select([selectedFile], in: model)
        model.pasteSymbolicLink()

        XCTAssertNil(model.errorMessage)
        for name in ["report.txt", "report 2.txt"] {
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
                atPath: nested.appendingPathComponent(name).path), source.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("report.txt").path))
    }

    func testCollisionPreservesRegularFileAndDanglingLink() throws {
        let source = try file("source/report.txt")
        let destination = try directory("destination")
        let existing = try file("destination/report.txt", contents: "keep me")
        let dangling = destination.appendingPathComponent("report 2.txt")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing")
        let model = FixtureExplorer(url: destination)
        FileExplorerViewModel.clipboard = [source]

        model.pasteSymbolicLink()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path), "missing")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent("report 3.txt").path), source.path)
    }

    func testSystemPasteboardSingleFileIsSupported() throws {
        let source = try file("source/report.txt")
        let destination = try directory("destination")
        let model = FixtureExplorer(url: destination)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.writeObjects([source as NSURL]))
        XCTAssertTrue(FileExplorerViewModel.clipboard.isEmpty)

        XCTAssertTrue(model.canPasteSymbolicLink)
        model.pasteSymbolicLink()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent("report.txt").path), source.path)
    }

    func testCutMultiItemAndNonFileClipboardsAreRejected() throws {
        let first = try file("source/first.txt")
        let second = try file("source/second.txt")
        let destination = try directory("destination")
        let model = FixtureExplorer(url: destination)
        for (urls, cut) in [([first], true), ([first, second], false),
                            ([try XCTUnwrap(URL(string: "https://example.com/file"))], false)] {
            FileExplorerViewModel.clipboard = urls
            FileExplorerViewModel.clipboardIsCut = cut
            XCTAssertFalse(model.canPasteSymbolicLink)
            model.pasteSymbolicLink()
            XCTAssertTrue(model.showError)
            XCTAssertTrue(model.undoStack.isEmpty)
            XCTAssertEqual(FileExplorerViewModel.clipboard, urls)
            XCTAssertEqual(FileExplorerViewModel.clipboardIsCut, cut)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testMissingSourceAndInvalidDestinationSurfaceErrors() throws {
        let source = try file("source/report.txt")
        let destination = try directory("destination")
        let model = FixtureExplorer(url: destination)
        FileExplorerViewModel.clipboard = [source]
        try FileManager.default.removeItem(at: source)

        model.pasteSymbolicLink()

        XCTAssertTrue(model.showError)
        XCTAssertTrue(model.errorMessage?.contains("Could not create symbolic link") == true)
        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)

        try Data("restored".utf8).write(to: source)
        model.navigateTo(root.appendingPathComponent("missing-destination"))
        model.pasteSymbolicLink()
        XCTAssertTrue(model.showError)
        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "restored")
    }
}
