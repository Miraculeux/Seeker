import Foundation
import XCTest
@testable import Seeker

final class TrashRestoreTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let records: URL
        let service: TrashRestoreService
        private var trashURLs: [URL] = []

        init() throws {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            root = repository.appendingPathComponent(".trash-restore-tests-\(UUID().uuidString)", isDirectory: true)
            records = root.appendingPathComponent("records", isDirectory: true)
            service = TrashRestoreService(recordsDirectory: records)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func file(_ label: String, contents: String = "test payload", directory: URL? = nil) throws -> URL {
            let parent = directory ?? root
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let url = parent.appendingPathComponent("\(root.lastPathComponent)-\(label)")
            try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
            return url
        }

        func folder(_ label: String) throws -> URL {
            let url = root.appendingPathComponent("\(root.lastPathComponent)-\(label)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }

        func trash(_ source: URL, native: Bool = false) throws -> URL {
            let target: URL
            if native {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
                target = try XCTUnwrap(resultingURL as URL?)
            } else {
                target = try service.trash(source)
            }
            trashURLs.append(target)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            return target
        }

        func onlyRecord() throws -> URL {
            let urls = try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)
            XCTAssertEqual(urls.count, 1)
            return try XCTUnwrap(urls.first)
        }

        func cleanup(file: StaticString = #filePath, line: UInt = #line) {
            // Never enumerate or empty Trash: remove only paths returned for this fixture.
            for url in trashURLs + [root] {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue
                } catch {
                    XCTFail("Fixture cleanup failed for \(url.path): \(error)", file: file, line: line)
                }
            }
        }
    }

    func testFileOriginPersistsAcrossServiceInstances() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.file("persistent-file", contents: "persistent file contents")
        let trashed = try fixture.trash(source)
        let restarted = TrashRestoreService(recordsDirectory: fixture.records)

        XCTAssertEqual(try restarted.originalURL(for: trashed)?.path, source.path)
        XCTAssertEqual(try restarted.restore(trashed).path, source.path)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "persistent file contents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertNil(try restarted.originalURL(for: trashed))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.records.path).isEmpty)
    }

    func testFolderOriginAndNestedContentsPersistAcrossServiceInstances() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.folder("persistent-folder")
        let child = try fixture.file("child", contents: "nested contents",
                                     directory: folder.appendingPathComponent("nested"))
        let trashed = try fixture.trash(folder)
        let restarted = TrashRestoreService(recordsDirectory: fixture.records)

        XCTAssertEqual(try restarted.originalURL(for: trashed)?.path, folder.path)
        XCTAssertEqual(try restarted.restore(trashed).path, folder.path)
        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "nested contents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertNil(try restarted.originalURL(for: trashed))
    }

    func testRestoreRecreatesMissingOriginalDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("removed-parent/nested")
        let source = try fixture.file("missing-parent", directory: parent)
        let trashed = try fixture.trash(source)
        try FileManager.default.removeItem(at: parent.deletingLastPathComponent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))

        XCTAssertEqual(try fixture.service.restore(trashed).path, source.path)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "test payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
    }

    func testNativeTrashRequiresExplicitDestination() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.file("native-file")
        let trashed = try fixture.trash(source, native: true)
        XCTAssertNil(try fixture.service.originalURL(for: trashed))
        XCTAssertThrowsError(try fixture.service.restore(trashed)) { error in
            XCTAssertTrue(error.localizedDescription.contains("original location is unknown"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        let destination = fixture.root.appendingPathComponent("chosen/restored-file")
        XCTAssertEqual(try fixture.service.restore(trashed, to: destination).path, destination.path)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "test payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testRestoreDoesNotOverwriteExistingDestination() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.file("collision", contents: "trashed contents")
        let trashed = try fixture.trash(source)
        try Data("replacement contents".utf8).write(to: source, options: .withoutOverwriting)

        XCTAssertThrowsError(try fixture.service.restore(trashed))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "replacement contents")
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "trashed contents")
        XCTAssertEqual(try fixture.service.originalURL(for: trashed)?.path, source.path)
    }

    func testOriginWriteFailureReturnsFileToSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default
        let source = try fixture.file("origin-write-failure")
        let trashDirectory = try fm.url(for: .trashDirectory, in: .userDomainMask,
                                       appropriateFor: source, create: true)
        let possibleTrashURL = trashDirectory.appendingPathComponent(source.lastPathComponent)
        XCTAssertFalse(fm.fileExists(atPath: possibleTrashURL.path))
        defer {
            if fm.fileExists(atPath: possibleTrashURL.path) {
                do { try fm.removeItem(at: possibleTrashURL) }
                catch { XCTFail("Could not clean up failed fixture: \(error)") }
            }
        }
        try fm.createDirectory(at: fixture.records, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o500])
        defer {
            do { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.records.path) }
            catch { XCTFail("Could not restore fixture permissions: \(error)") }
        }
        XCTAssertThrowsError(try fixture.service.trash(source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("returned to"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "test payload")
        XCTAssertFalse(fm.fileExists(atPath: possibleTrashURL.path))
    }

    func testRetrashingAndRestoringInsideTrashAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.file("already-trashed")
        let folder = try fixture.folder("trashed-folder")
        let trashed = try fixture.trash(source)
        let trashedFolder = try fixture.trash(folder)
        XCTAssertThrowsError(try fixture.service.trash(trashed))
        XCTAssertThrowsError(try fixture.service.restore(trashed, to: trashedFolder.appendingPathComponent("nested")))
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "test payload")
        XCTAssertEqual(try fixture.service.originalURL(for: trashed)?.path, source.path)
    }

    func testRestoreDoesNotOverwriteDanglingDestinationSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.file("dangling-collision")
        let trashed = try fixture.trash(source)
        let missingTarget = fixture.root.appendingPathComponent("nonexistent-symlink-target")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: missingTarget)

        XCTAssertThrowsError(try fixture.service.restore(trashed))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), missingTarget.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "test payload")
        XCTAssertEqual(try fixture.service.originalURL(for: trashed)?.path, source.path)
    }

    func testCorruptAndInvalidOriginRecordsAreReportedWithoutMovingItem() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.file("bad-record")
        let trashed = try fixture.trash(source)
        let record = try fixture.onlyRecord()
        let invalidSchema = try PropertyListSerialization.data(
            fromPropertyList: ["originalURL": 42], format: .xml, options: 0)

        for contents in [Data("not a property list".utf8), invalidSchema] {
            try contents.write(to: record)
            let restarted = TrashRestoreService(recordsDirectory: fixture.records)
            XCTAssertThrowsError(try restarted.originalURL(for: trashed))
            XCTAssertThrowsError(try restarted.restore(trashed))
            XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: record), contents)
        }
    }

    func testStaleRecordCannotRestoreDifferentFileReusingTrashPathname() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.file("stale-original", contents: "original identity")
        let trashed = try fixture.trash(source)
        let retained = fixture.root.appendingPathComponent("retained-original")
        // Retaining the old inode prevents immediate inode recycling from weakening this test.
        try FileManager.default.moveItem(at: trashed, to: retained)
        let replacement = try fixture.file("replacement", contents: "different identity")
        let replacementTrash = try fixture.trash(replacement, native: true)
        try FileManager.default.moveItem(at: replacementTrash, to: trashed)
        let restarted = TrashRestoreService(recordsDirectory: fixture.records)

        XCTAssertNil(try restarted.originalURL(for: trashed))
        XCTAssertThrowsError(try restarted.restore(trashed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "different identity")
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "original identity")
        let destination = fixture.root.appendingPathComponent("explicit-replacement")
        XCTAssertEqual(try restarted.restore(trashed, to: destination).path, destination.path)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "different identity")
    }

    @MainActor
    func testViewModelRestoresKnownFileAndFolderBatchAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.file("known-batch-file")
        let folder = try fixture.folder("known-batch-folder")
        let child = try fixture.file("child", directory: folder)
        let trashed = try [fixture.trash(source), fixture.trash(folder)]
        let model = selectedModel(fixture, urls: trashed)

        XCTAssertTrue(model.canRestoreFromTrash)
        model.restoreSelectedFromTrash()
        XCTAssertNotNil(model.fileMutationStatus)
        XCTAssertFalse(model.canRestoreFromTrash)
        try await waitForRestore(model)

        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "test payload")
        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "test payload")
        for url in trashed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    func testViewModelMixedBatchUsesFallbackOnlyForUnknownOrigins() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let known = try fixture.file("mixed-known", contents: "known payload")
        let unknown = try fixture.file("mixed-unknown", contents: "unknown payload")
        let unknownFolder = try fixture.folder("mixed-unknown-folder")
        let child = try fixture.file("child", contents: "unknown nested payload", directory: unknownFolder)
        let knownTrash = try fixture.trash(known)
        let unknownTrash = try fixture.trash(unknown, native: true)
        let folderTrash = try fixture.trash(unknownFolder, native: true)
        let fallback = try fixture.folder("chosen-fallback")
        let model = selectedModel(fixture, urls: [knownTrash, unknownTrash, folderTrash])

        XCTAssertTrue(model.canRestoreFromTrash)
        model.restoreSelectedFromTrash(to: fallback)
        try await waitForRestore(model)

        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(try String(contentsOf: known, encoding: .utf8), "known payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.appendingPathComponent(knownTrash.lastPathComponent).path))
        XCTAssertEqual(try String(contentsOf: fallback.appendingPathComponent(unknownTrash.lastPathComponent),
                                  encoding: .utf8), "unknown payload")
        let restoredChild = fallback.appendingPathComponent(folderTrash.lastPathComponent)
            .appendingPathComponent(child.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: restoredChild, encoding: .utf8), "unknown nested payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknownFolder.path))
        for url in [knownTrash, unknownTrash, folderTrash] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    func testViewModelReportsCorruptRecordWithoutRestoringBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try fixture.file("viewmodel-corrupt")
        let trashed = try fixture.trash(source)
        try Data("corrupt origin".utf8).write(to: fixture.onlyRecord())
        let model = selectedModel(fixture, urls: [trashed])

        model.restoreSelectedFromTrash(to: fixture.root)
        try await waitForRestore(model)

        XCTAssertTrue(model.showError)
        XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("Could not restore from Trash"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    private func selectedModel(_ fixture: Fixture, urls: [URL]) -> FileExplorerViewModel {
        // Browse only our fixture, injecting exact selections without listing the user's Trash.
        let model = FileExplorerViewModel(
            url: fixture.root, trashService: TrashRestoreService(recordsDirectory: fixture.records))
        model.files = urls.map { FileItem(url: $0) }
        model.selectedFileIDs = Set(model.files.map(\.id))
        return model
    }

    @MainActor
    private func waitForRestore(_ model: FileExplorerViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while model.fileMutationStatus != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.fileMutationStatus, "Restore did not finish within 15 seconds")
    }
}
