import Foundation
import XCTest
@testable import Seeker

@MainActor
final class FileOperationWorkflowTests: XCTestCase {
    private final class FixtureExplorer: FileExplorerViewModel {
        override func navigateTo(_ url: URL) { currentURL = url }
        override func loadFiles() {}
    }

    func testPlannedBatchCreatesNestedParentsAndCopiesExactBytes() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let first = try fixture.write("source/first.bin", "first\u{0}payload")
        let second = try fixture.write("source/empty", "")
        let manager = FileOperationManager()
        var callbacks = 0
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: first, destination: fixture.url("output/deep/renamed.bin"), replace: false),
            .init(source: second, destination: fixture.url("output/empty"), replace: false)
        ]) { _ in callbacks += 1 })

        try await completeWorkflowOperation(operation)
        XCTAssertNil(operation.error)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(operation.filesCompleted, 2)
        XCTAssertEqual(operation.filesTotal, 2)
        XCTAssertEqual(operation.totalBytes, 13)
        XCTAssertEqual(operation.copiedBytes, 13)
        XCTAssertEqual(operation.progress, 1)
        XCTAssertEqual(operation.completedDestinations, [fixture.url("output/deep/renamed.bin"), fixture.url("output/empty")])
        XCTAssertEqual(try fixture.contents("output/deep/renamed.bin"), "first\u{0}payload")
        XCTAssertEqual(try fixture.contents("output/empty"), "")
        XCTAssertEqual(try fixture.contents("source/first.bin"), "first\u{0}payload")
        XCTAssertFalse(manager.hasActiveOperations)
        XCTAssertNil(manager.runningOperation)
    }

    func testRecursiveCopyIncludesHiddenFilesAndPreservesSourceTree() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.directory("source")
        try fixture.write("source/deep/leaf.txt", "nested")
        try fixture.write("source/.secret", "hidden")
        try fixture.write("source/zero", "")
        try FileManager.default.createSymbolicLink(atPath: fixture.url("source/directory-link").path,
                                                  withDestinationPath: "deep")
        try FileManager.default.createSymbolicLink(atPath: fixture.url("source/broken-link").path,
                                                  withDestinationPath: "missing")
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: source, destination: fixture.url("output"), replace: false)
        ]) { _ in })

        try await completeWorkflowOperation(operation)
        XCTAssertNil(operation.error)
        XCTAssertTrue(operation.skippedItems.isEmpty)
        XCTAssertEqual(operation.filesCompleted, 1)
        for path in ["deep/leaf.txt", ".secret", "zero"] {
            XCTAssertEqual(try fixture.contents("output/\(path)"), try fixture.contents("source/\(path)"))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url("output/directory-link").path), "deep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url("output/broken-link").path), "missing")
    }

    func testOverwriteShorterFileRemovesOldTailAndLeavesSourceIntact() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("source", "new")
        let destination = try fixture.write("output", "old payload with a much longer tail")
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: source, destination: destination, replace: true)
        ]) { _ in })

        try await completeWorkflowOperation(operation)
        XCTAssertNil(operation.error)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertEqual(try fixture.contents("source"), "new")
        XCTAssertEqual(operation.totalBytes, 3)
        XCTAssertEqual(operation.copiedBytes, 3)
        XCTAssertEqual(operation.completedDestinations, [destination])

        // An existing destination prevents clonefile, exercising the streamed-copy path.
        try fixture.write("output", "a second longer payload")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let streamed = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: source, destination: destination, replace: false)
        ]) { _ in })
        try await completeWorkflowOperation(streamed)
        XCTAssertNil(streamed.error)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertEqual(streamed.copiedBytes, 3)
        XCTAssertEqual(streamed.progress, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(modificationDate.timeIntervalSince1970, 1_700_000_000, accuracy: 0.01)
    }

    func testOverwriteReplacesDirectoryInsteadOfMergingStaleChildren() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.directory("source")
        try fixture.write("source/nested/new", "fresh")
        try fixture.write("output/stale", "must disappear")
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: source, destination: fixture.url("output"), replace: true)
        ]) { _ in })

        try await completeWorkflowOperation(operation)
        XCTAssertNil(operation.error)
        XCTAssertFalse(fixture.exists("output/stale"))
        XCTAssertEqual(try fixture.contents("output/nested/new"), "fresh")
        XCTAssertEqual(try fixture.contents("source/nested/new"), "fresh")
    }

    func testCopyInPlaceChoosesNextAvailableNameWithoutClobberingSiblings() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("report.txt", "original")
        try fixture.write("report 2.txt", "reserved")
        let manager = FileOperationManager()
        manager.startCopy(sources: [source], to: fixture.root) { _ in }
        let operation = try XCTUnwrap(manager.operations.first)

        try await completeWorkflowOperation(operation)
        XCTAssertNil(operation.error)
        XCTAssertEqual(operation.completedDestinations, [fixture.url("report 3.txt")])
        XCTAssertEqual(try fixture.contents("report.txt"), "original")
        XCTAssertEqual(try fixture.contents("report 2.txt"), "reserved")
        XCTAssertEqual(try fixture.contents("report 3.txt"), "original")
    }

    func testMoveInPlaceIsNoOpAndDoesNotCallCompletion() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("keep.txt", "untouched")
        let manager = FileOperationManager()
        var completed = false
        manager.startMove(sources: [source], to: fixture.root) { _ in completed = true }

        XCTAssertTrue(manager.operations.isEmpty)
        XCTAssertFalse(completed)
        XCTAssertEqual(try fixture.contents("keep.txt"), "untouched")
    }

    func testBlockedParentStopsBatchAndPreservesAllSources() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let first = try fixture.write("source/first", "first")
        let second = try fixture.write("source/second", "second")
        try fixture.write("blocker", "not a directory")
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: first, destination: fixture.url("blocker/child"), replace: false),
            .init(source: second, destination: fixture.url("output/second"), replace: false)
        ]) { _ in })

        try await completeWorkflowOperation(operation)
        XCTAssertNotNil(operation.error)
        XCTAssertTrue(operation.dismissalScheduled)
        XCTAssertEqual(operation.filesCompleted, 0)
        XCTAssertTrue(operation.completedDestinations.isEmpty)
        XCTAssertFalse(fixture.exists("output/second"))
        XCTAssertEqual(try fixture.contents("source/first"), "first")
        XCTAssertEqual(try fixture.contents("source/second"), "second")
        XCTAssertEqual(try fixture.contents("blocker"), "not a directory")
    }

    func testMissingSourceReportsFailureWithoutRecordingCompletion() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let missing = fixture.url("missing")
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: missing, destination: fixture.url("output"), replace: false)
        ]) { _ in })

        try await completeWorkflowOperation(operation)
        XCTAssertTrue(operation.skippedItems.isEmpty)
        XCTAssertNotNil(operation.error)
        XCTAssertEqual(operation.filesCompleted, 0)
        XCTAssertTrue(operation.completedDestinations.isEmpty)
        XCTAssertFalse(fixture.exists("output"))
        XCTAssertEqual(operation.copiedBytes, 0)
    }

    func testMissingSourceOverwritePreservesExistingDestinationAndDoesNotRecordSuccess() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let missing = fixture.url("missing-source")
        let destination = try fixture.write("output", "irreplaceable destination contents")
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: missing, destination: destination, replace: true)
        ]) { _ in })

        try await completeWorkflowOperation(operation)
        XCTAssertTrue(operation.skippedItems.isEmpty)
        XCTAssertNotNil(operation.error)
        XCTAssertTrue(fixture.exists("output"), "A missing source must not delete the existing destination")
        if fixture.exists("output") {
            XCTAssertEqual(try Data(contentsOf: destination), Data("irreplaceable destination contents".utf8))
        }
        XCTAssertEqual(operation.filesCompleted, 0, "A skipped source is not a successfully copied item")
        XCTAssertTrue(operation.completedDestinations.isEmpty, "Undo/progress must not record a nonexistent destination")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["output"])
    }

    func testMissingSourceOverwritePreservesExistingDirectoryTree() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        try fixture.write("output/nested/original", "preserve the tree")
        try fixture.directory("output/empty")
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: fixture.url("missing-directory"), destination: fixture.url("output"), replace: true)
        ]) { _ in })

        try await completeWorkflowOperation(operation)
        XCTAssertNotNil(operation.error)
        XCTAssertEqual(operation.filesCompleted, 0)
        XCTAssertTrue(operation.completedDestinations.isEmpty)
        XCTAssertEqual(try fixture.contents("output/nested/original"), "preserve the tree")
        XCTAssertEqual(Set(try FileManager.default.subpathsOfDirectory(atPath: fixture.url("output").path)),
                       ["empty", "nested", "nested/original"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["output"])
    }

    func testUnreadableChildOverwritePreservesFileAndDirectoryTargetsAndCleansStaging() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.directory("source")
        try fixture.write("source/readable", "new readable content")
        let unreadable = try fixture.write("source/unreadable", "new unreadable content")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        }
        guard !FileManager.default.isReadableFile(atPath: unreadable.path) else {
            throw XCTSkip("This account can read mode-000 files; cannot induce a deterministic read failure")
        }
        let fileTarget = try fixture.write("file-target", "original file")
        try fixture.write("directory-target/nested/original", "original directory")
        try fixture.directory("directory-target/empty")
        let manager = FileOperationManager()

        for destination in [fileTarget, fixture.url("directory-target")] {
            let operation = try XCTUnwrap(manager.startPlannedCopy([
                .init(source: source, destination: destination, replace: true)
            ]) { _ in })
            try await completeWorkflowOperation(operation)
            XCTAssertNotNil(operation.error)
            XCTAssertEqual(operation.filesCompleted, 0)
            XCTAssertTrue(operation.completedDestinations.isEmpty)
            XCTAssertEqual(try fixture.contents("file-target"), "original file")
            XCTAssertEqual(try fixture.contents("directory-target/nested/original"), "original directory")
            XCTAssertTrue(fixture.exists("directory-target/empty"))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)),
                           ["source", "file-target", "directory-target"])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        XCTAssertEqual(try fixture.contents("source/unreadable"), "new unreadable content")
        XCTAssertEqual(try fixture.contents("source/readable"), "new readable content")
    }

    func testOverwriteCopiesDanglingSymbolicLinkWithoutFollowingItsTarget() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = fixture.url("source-link")
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "missing-target")
        let destination = try fixture.write("output", "old contents")
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: source, destination: destination, replace: true)
        ]) { _ in })

        try await completeWorkflowOperation(operation)
        XCTAssertNil(operation.error)
        XCTAssertEqual(operation.filesCompleted, 1)
        XCTAssertEqual(operation.completedDestinations, [destination])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "missing-target")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), "missing-target")
        XCTAssertFalse(fixture.exists("missing-target"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)), ["source-link", "output"])
    }

    func testUnwritableDestinationParentPreservesFileAndDirectoryTargets() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let sourceFile = try fixture.write("source-file", "replacement file")
        let sourceDirectory = try fixture.directory("source-directory")
        try fixture.write("source-directory/new", "replacement child")
        let parent = try fixture.directory("locked")
        let fileTarget = try fixture.write("locked/file", "original file")
        try fixture.write("locked/directory/original", "original directory")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        }
        guard !FileManager.default.isWritableFile(atPath: parent.path) else {
            throw XCTSkip("This account can write mode-555 directories; cannot induce a deterministic write failure")
        }
        let manager = FileOperationManager()
        for (source, destination) in [(sourceFile, fileTarget), (sourceDirectory, fixture.url("locked/directory"))] {
            let operation = try XCTUnwrap(manager.startPlannedCopy([
                .init(source: source, destination: destination, replace: true)
            ]) { _ in })
            try await completeWorkflowOperation(operation)
            XCTAssertNotNil(operation.error)
            XCTAssertEqual(operation.filesCompleted, 0)
            XCTAssertTrue(operation.completedDestinations.isEmpty)
            XCTAssertEqual(try fixture.contents("locked/file"), "original file")
            XCTAssertEqual(try fixture.contents("locked/directory/original"), "original directory")
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: parent.path)), ["file", "directory"])
        }
        XCTAssertEqual(try fixture.contents("source-file"), "replacement file")
        XCTAssertEqual(try fixture.contents("source-directory/new"), "replacement child")
    }

    func testDirectoryCopyPreservesEmptySourceRootAndNestedEmptyDirectories() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let tree = try fixture.directory("source/tree")
        try fixture.directory("source/tree/empty")
        try fixture.directory("source/tree/deep/empty")
        try fixture.write("source/tree/kept.txt", "payload")
        let emptyRoot = try fixture.directory("source/empty-root")
        try FileManager.default.setAttributes([
            .posixPermissions: 0o750,
            .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        ], ofItemAtPath: tree.path)
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: tree, destination: fixture.url("output/tree"), replace: false),
            .init(source: emptyRoot, destination: fixture.url("output/empty-root"), replace: false)
        ]) { _ in })

        try await completeWorkflowOperation(operation)
        XCTAssertNil(operation.error)
        XCTAssertEqual(operation.filesCompleted, 2)
        XCTAssertEqual(try fixture.contents("output/tree/kept.txt"), "payload")
        for path in ["output/tree/empty", "output/tree/deep/empty", "output/empty-root"] {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: fixture.url(path).path, isDirectory: &isDirectory)
            XCTAssertTrue(exists && isDirectory.boolValue, "Directory copy must preserve \(path), even without file children")
        }
        XCTAssertEqual(Set(try FileManager.default.subpathsOfDirectory(atPath: fixture.url("output/tree").path)),
                       ["empty", "deep", "deep/empty", "kept.txt"])
        XCTAssertEqual(Set(try FileManager.default.subpathsOfDirectory(atPath: tree.path)),
                       ["empty", "deep", "deep/empty", "kept.txt"])
        XCTAssertTrue(fixture.exists("source/empty-root"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url("output/tree").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o750)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(modificationDate.timeIntervalSince1970, 1_700_000_000, accuracy: 0.01)
    }

    func testCancellationBeforeOverwritePreservesExistingDestination() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("source", "new")
        let target = try fixture.write("output", "old contents must survive")
        let manager = FileOperationManager()
        let operation = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: source, destination: target, replace: true)
        ]) { _ in })
        operation.cancel()

        try await completeWorkflowOperation(operation)
        XCTAssertTrue(operation.isCancelled)
        XCTAssertNil(operation.error)
        XCTAssertEqual(operation.filesCompleted, 0)
        XCTAssertTrue(operation.completedDestinations.isEmpty)
        XCTAssertEqual(try fixture.contents("output"), "old contents must survive")
        XCTAssertEqual(try fixture.contents("source"), "new")
    }

    func testSameVolumeQueueDropsCancelledBatchAndResumesFirstCopy() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("source", "payload")
        let manager = FileOperationManager()
        manager.togglePause()
        defer { manager.isPaused = false }
        let first = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: source, destination: fixture.url("output/first"), replace: false)
        ]) { _ in })
        var cancelledCallback = false
        let second = try XCTUnwrap(manager.startPlannedCopy([
            .init(source: source, destination: fixture.url("output/second"), replace: false)
        ]) { _ in cancelledCallback = true })
        XCTAssertTrue(manager.isPaused)
        XCTAssertTrue(manager.runningOperation === first)
        XCTAssertTrue(second.isQueued)
        XCTAssertEqual(manager.queuedCount, 1)
        second.cancel()
        manager.togglePause()

        try await completeWorkflowOperation(first)
        XCTAssertFalse(manager.operations.contains { $0.id == second.id })
        XCTAssertFalse(cancelledCallback)
        XCTAssertEqual(manager.queuedCount, 0)
        XCTAssertFalse(manager.hasActiveOperations)
        XCTAssertEqual(try fixture.contents("output/first"), "payload")
        XCTAssertFalse(fixture.exists("output/second"))
    }

    func testMoveSelectionRecordsUndoAndUndoRestoresNestedTree() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.directory("source/tree")
        let destination = try fixture.directory("destination")
        try fixture.write("source/tree/deep/child", "recoverable")
        let model = FixtureExplorer(
            url: fixture.url("source"),
            trashService: TrashRestoreService(recordsDirectory: fixture.url("trash-records"))
        )
        defer { model.cancelLoading() }
        model.cancelLoading()
        model.files = [FileItem(url: source)]
        model.selectedFileIDs = Set(model.files.map(\.id))
        model.moveSelectedTo(destination: destination)
        try await waitForWorkflow { !model.undoStack.isEmpty }
        XCTAssertFalse(fixture.exists("source/tree"))
        XCTAssertEqual(try fixture.contents("destination/tree/deep/child"), "recoverable")
        guard case .move(let originals, let destinations) = try XCTUnwrap(model.undoStack.last) else {
            return XCTFail("Move must record its exact source and completed destination")
        }
        XCTAssertEqual(originals, [source])
        XCTAssertEqual(destinations.map(\.standardizedFileURL.path),
                       [fixture.url("destination/tree").standardizedFileURL.path])

        model.undo()
        try await waitForWorkflow { model.fileMutationStatus == nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertEqual(try fixture.contents("source/tree/deep/child"), "recoverable")
        XCTAssertFalse(fixture.exists("destination/tree"))
    }
}
