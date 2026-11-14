import AppKit
import XCTest
@testable import Seeker

@MainActor
final class FileDropWorkflowTests: XCTestCase {
    private final class FixtureExplorer: FileExplorerViewModel {
        var reloads = 0
        override func navigateTo(_ url: URL) { currentURL = url }
        override func loadFiles() { reloads += 1 }
    }

    func testSameDirectoryDropDoesNotCopyOrChangeUndoHistory() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("original.txt", "original")
        let model = FixtureExplorer(url: fixture.root)
        defer { model.cancelLoading() }
        model.undoStack = [.create(url: source)]
        let operationIDs = FileOperationManager.shared.operations.map(\.id)

        for move in [false, true] {
            XCTAssertFalse(model.dropFiles(sources: [source], to: fixture.root,
                                           isMove: move, copyInPlace: false))
        }
        XCTAssertFalse(model.dropFiles(sources: [source], to: fixture.root,
                                       isMove: true, copyInPlace: true))
        XCTAssertEqual(FileOperationManager.shared.operations.map(\.id), operationIDs)
        XCTAssertEqual(model.undoStack.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["original.txt"])
        XCTAssertEqual(try fixture.contents("original.txt"), "original")
    }

    func testDropPolicyResolvesParentAliasesButNotTheDraggedSymlink() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let directory = try fixture.directory("source")
        let source = try fixture.write("source/file.txt", "payload")
        let alias = fixture.url("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let fileLink = fixture.url("source/link.txt")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: fixture.url("elsewhere"))

        XCTAssertTrue(FileExplorerViewModel.sourcesForDrop([source, fileLink], to: alias,
                                                           copyInPlace: false).isEmpty)
        XCTAssertTrue(FileExplorerViewModel.sourcesForDrop([alias.appendingPathComponent("file.txt")],
                                                           to: directory, copyInPlace: false).isEmpty)
        XCTAssertEqual(FileExplorerViewModel.sourcesForDrop([source], to: alias, copyInPlace: true), [source])
    }

    func testMixedDropSkipsOnlyFilesAlreadyInDestination() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let local = try fixture.write("destination/local.txt", "local")
        let incoming = try fixture.write("source/incoming.txt", "incoming")
        let destination = fixture.url("destination")
        let model = FixtureExplorer(url: destination)
        defer { model.cancelLoading() }

        XCTAssertTrue(model.dropFiles(sources: [local, incoming], to: destination,
                                      isMove: false, copyInPlace: false))
        try await waitForWorkflow { model.canUndo }
        guard case .copy(let copied) = model.undoStack.last else {
            return XCTFail("A file drop must record a copy action")
        }
        XCTAssertEqual(copied, [fixture.url("destination/incoming.txt")])
        XCTAssertEqual(try fixture.contents("destination/local.txt"), "local")
        XCTAssertEqual(try fixture.contents("destination/incoming.txt"), "incoming")
        XCTAssertFalse(fixture.exists("destination/local 2.txt"))
        XCTAssertTrue(fixture.exists("source/incoming.txt"))
    }

    func testSameDirectoryPasteStillCreatesUndoableDuplicate() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("file.txt", "payload")
        let model = FixtureExplorer(url: fixture.root)
        defer { model.cancelLoading() }
        let savedClipboard = FileExplorerViewModel.clipboard
        let savedCut = FileExplorerViewModel.clipboardIsCut
        defer {
            FileExplorerViewModel.clipboard = savedClipboard
            FileExplorerViewModel.clipboardIsCut = savedCut
        }
        FileExplorerViewModel.clipboard = [source]
        FileExplorerViewModel.clipboardIsCut = false

        model.paste()
        try await waitForWorkflow { model.canUndo }
        guard case .copy(let destinations) = model.undoStack.last else {
            return XCTFail("Paste must still record its duplicate")
        }
        XCTAssertEqual(destinations, [fixture.url("file 2.txt")])
        XCTAssertEqual(try fixture.contents("file.txt"), "payload")
        XCTAssertEqual(try fixture.contents("file 2.txt"), "payload")
    }

    func testCrossPaneMergeRefreshesDestinationAndKeepsUndoWithInitiator() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.directory("source/tree")
        try fixture.write("source/tree/nested/new.txt", "new")
        try fixture.write("destination/tree/nested/existing.txt", "existing")
        let sender = FixtureExplorer(url: fixture.url("source"))
        let receiver = FixtureExplorer(url: fixture.url("destination"))
        defer {
            sender.cancelLoading()
            receiver.cancelLoading()
        }
        let reloads = receiver.reloads

        sender.transferFiles(sources: [source], to: receiver.currentURL, isMove: false)
        try await waitForWorkflow { sender.canUndo }

        XCTAssertGreaterThan(receiver.reloads, reloads)
        XCTAssertTrue(receiver.undoStack.isEmpty)
        XCTAssertEqual(try fixture.contents("destination/tree/nested/new.txt"), "new")
        XCTAssertEqual(try fixture.contents("destination/tree/nested/existing.txt"), "existing")
        guard case .copy(let destinations) = sender.undoStack.last else {
            return XCTFail("Cross-pane commands must retain Undo in the initiating pane")
        }
        XCTAssertEqual(destinations, [fixture.url("destination/tree/nested/new.txt")])
    }

    func testCopyDropAfterEmptyingTrashUndoesCopyInsteadOfOldDeletion() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let service = TrashRestoreService(recordsDirectory: fixture.url("trash-records"))
        let deleted = try fixture.write("deleted-\(UUID().uuidString).txt", "deleted")
        let model = FixtureExplorer(url: fixture.root, trashService: service)
        defer { model.cancelLoading() }
        model.files = [FileItem(url: deleted)]
        model.selectedFileIDs = Set(model.files.map(\.id))
        model.trashSelected()
        try await waitForWorkflow { model.fileMutationStatus == nil }
        guard case .trash(_, let trashURLs) = model.undoStack.last else {
            return XCTFail("Deletion must be undoable before emptying Trash")
        }
        // Empty only this test's disposable Trash item, never the user's Trash.
        for url in trashURLs { try FileManager.default.removeItem(at: url) }
        let name = "copy-\(UUID().uuidString).txt"
        let source = try fixture.write(name, "original")
        let copy = fixture.url(source.deletingPathExtension().lastPathComponent + " 2.txt")
        defer { removeTrashedCopy(of: copy, using: service) }
        let manager = FileOperationManager.shared
        let wasPaused = manager.isPaused
        manager.isPaused = true
        defer { manager.isPaused = wasPaused }
        model.receiveFileDrop(providers: [provider(for: source)], to: fixture.root,
                              isMove: false, copyInPlace: true)

        XCTAssertFalse(model.canUndo, "Decoding providers must block Undo of the earlier deletion")
        model.undo()
        XCTAssertEqual(model.undoStack.count, 1)
        try await waitForWorkflow { model.fileMutationStatus == nil }
        let operation = try XCTUnwrap(manager.operations.last)
        defer { if !operation.isFinished { operation.cancel() } }
        XCTAssertFalse(model.canUndo, "An unfinished copy must not expose the old deletion to Undo")
        model.undo()
        XCTAssertEqual(model.undoStack.count, 1)
        XCTAssertNil(model.errorMessage)
        manager.isPaused = false
        try await completeWorkflowOperation(operation)
        XCTAssertEqual(model.undoStack.count, 2)
        guard case .copy(let destinations) = model.undoStack.last else {
            return XCTFail("Drop must be the most recent undoable action")
        }
        XCTAssertEqual(destinations, [copy])
        XCTAssertEqual(try Data(contentsOf: copy), Data("original".utf8))

        model.undo()
        try await waitForWorkflow { model.fileMutationStatus == nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.undoStack.count, 1, "The old deletion must not be consumed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.path))
    }

    func testMoveDropRecordsExactURLsAndUndoRestoresSource() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("source/file.txt", "payload")
        let destination = try fixture.directory("destination")
        let model = FixtureExplorer(url: destination)
        defer { model.cancelLoading() }
        model.receiveFileDrop(providers: [provider(for: source)], to: destination,
                              isMove: true, copyInPlace: false)
        try await waitForWorkflow { model.canUndo }
        guard case .move(let originals, let destinations) = model.undoStack.last else {
            return XCTFail("Move drop must record its source/destination pair")
        }
        XCTAssertEqual(originals, [source])
        XCTAssertEqual(destinations, [fixture.url("destination/file.txt")])
        XCTAssertFalse(fixture.exists("source/file.txt"))
        model.undo()
        try await waitForWorkflow { model.fileMutationStatus == nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try fixture.contents("source/file.txt"), "payload")
        XCTAssertFalse(fixture.exists("destination/file.txt"))
    }

    func testSameDirectoryProviderDropDoesNotCreateCopy() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("file.txt", "payload")
        let model = FixtureExplorer(url: fixture.root)
        defer { model.cancelLoading() }
        model.receiveFileDrop(providers: [provider(for: source)], to: fixture.root,
                              isMove: false, copyInPlace: false)
        try await waitForWorkflow { model.fileMutationStatus == nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertFalse(fixture.exists("file 2.txt"))
    }

    func testInvalidProviderReportsErrorWithoutStartingTransfer() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let model = FixtureExplorer(url: fixture.root)
        defer { model.cancelLoading() }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadNoSuchFile))
            return nil
        }
        model.receiveFileDrop(providers: [provider], to: fixture.root,
                              isMove: false, copyInPlace: false)
        try await waitForWorkflow { model.fileMutationStatus == nil }
        XCTAssertTrue(model.showError)
        XCTAssertTrue(model.errorMessage?.hasPrefix("Could not read dropped files:") == true)
        XCTAssertTrue(model.undoStack.isEmpty)
    }

    func testCancellingRunningTransferStillBlocksUndoUntilCleanupFinishes() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("file.txt", "payload")
        let model = FixtureExplorer(url: fixture.root)
        defer { model.cancelLoading() }
        model.undoStack = [.create(url: source)]
        let operation = FileOperation(kind: .copy, sourceURLs: [source], destinationDir: fixture.root)
        operation.isQueued = false
        operation.cancel()
        FileOperationManager.shared.operations.append(operation)
        defer { FileOperationManager.shared.operations.removeAll { $0.id == operation.id } }

        XCTAssertFalse(model.canUndo)
        model.undo()
        XCTAssertEqual(model.undoStack.count, 1)
        XCTAssertTrue(fixture.exists("file.txt"))
        operation.isFinished = true
        XCTAssertTrue(model.canUndo)
    }

    private func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        return provider
    }

    private func removeTrashedCopy(of original: URL, using service: TrashRestoreService) {
        for url in TrashDiagnostics.listing().urls where url.lastPathComponent == original.lastPathComponent {
            do {
                if try service.originalURL(for: url) == original {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                XCTFail("Could not clean up disposable copy: \(error)")
            }
        }
    }
}
