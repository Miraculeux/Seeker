import Foundation
import XCTest
@testable import Seeker

@MainActor
final class DirectoryViewStateStoreTests: XCTestCase {
    private let customState = DirectoryViewState(
        sortOrder: "size", sortAscending: false, viewMode: "icons", showHiddenFiles: true
    )
    private let otherState = DirectoryViewState(
        sortOrder: "name", sortAscending: true, viewMode: "list", showHiddenFiles: false
    )

    func testStateRoundTripsThroughPropertyList() throws {
        let data = try PropertyListEncoder().encode(customState)
        XCTAssertEqual(try PropertyListDecoder().decode(DirectoryViewState.self, from: data), customState)
    }

    func testNewStoreDoesNotCreateBackingFileUntilChanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = DirectoryViewStateStore(fileURL: fixture.file)

        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.state(for: fixture.root))
        store.flushNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testStandardizedDirectoryKeysShareStateWithoutLeakingToOtherFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = DirectoryViewStateStore(fileURL: fixture.file)
        let directory = fixture.root.appendingPathComponent("photos", isDirectory: true)
        let alias = fixture.root.appendingPathComponent("other/../photos/", isDirectory: true)
        let other = fixture.root.appendingPathComponent("other", isDirectory: true)

        store.setState(customState, for: directory)
        XCTAssertEqual(store.state(for: alias), customState)
        XCTAssertNil(store.state(for: other))
        store.setState(otherState, for: alias)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.state(for: directory), otherState)
        store.flushNow()
    }

    func testFlushPersistsLatestSnapshotAndReloadsIndependentDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("first")
        let second = fixture.root.appendingPathComponent("second")
        let store = DirectoryViewStateStore(fileURL: fixture.file)
        store.setState(otherState, for: first)
        store.setState(customState, for: first)
        store.setState(otherState, for: second)
        store.flushNow()

        let reloaded = DirectoryViewStateStore(fileURL: fixture.file)
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.state(for: first), customState)
        XCTAssertEqual(reloaded.state(for: second), otherState)
    }

    func testRemovingOneStatePersistsWithoutRemovingAnother() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("first")
        let second = fixture.root.appendingPathComponent("second")
        let store = DirectoryViewStateStore(fileURL: fixture.file)
        store.setState(customState, for: first)
        store.setState(otherState, for: second)
        store.flushNow()
        store.removeState(for: first)
        store.removeState(for: fixture.root.appendingPathComponent("unknown"))
        store.flushNow()

        let reloaded = DirectoryViewStateStore(fileURL: fixture.file)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertNil(reloaded.state(for: first))
        XCTAssertEqual(reloaded.state(for: second), otherState)
    }

    func testPruningMissingDirectoriesPreservesExistingDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = fixture.root.appendingPathComponent("existing", isDirectory: true)
        let missing = fixture.root.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let store = DirectoryViewStateStore(fileURL: fixture.file)
        store.setState(customState, for: existing)
        store.setState(otherState, for: missing)
        store.pruneMissing()
        store.flushNow()

        XCTAssertEqual(store.count, 1)
        let reloaded = DirectoryViewStateStore(fileURL: fixture.file)
        XCTAssertEqual(reloaded.state(for: existing), customState)
        XCTAssertNil(reloaded.state(for: missing))
    }

    func testResetCancelsPendingSnapshotAndDeletesBackingFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = DirectoryViewStateStore(fileURL: fixture.file)
        store.setState(customState, for: fixture.root)
        store.flushNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        store.setState(otherState, for: fixture.root)
        store.removeAll()
        XCTAssertEqual(store.count, 0)

        // Wait beyond the debounce window to catch a cancelled snapshot being written back.
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertEqual(DirectoryViewStateStore(fileURL: fixture.file).count, 0)
    }

    func testStateSavedImmediatelyAfterResetSurvivesQueuedDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = DirectoryViewStateStore(fileURL: fixture.file)
        store.setState(customState, for: fixture.root)
        store.flushNow()
        store.removeAll()
        store.setState(otherState, for: fixture.root)
        store.flushNow()

        let reloaded = DirectoryViewStateStore(fileURL: fixture.file)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.state(for: fixture.root), otherState)
    }

    func testMalformedBackingFileDoesNotPreventFuturePersistence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not a property list".utf8).write(to: fixture.file)
        let store = DirectoryViewStateStore(fileURL: fixture.file)
        XCTAssertEqual(store.count, 0)
        store.setState(customState, for: fixture.root)
        store.flushNow()

        XCTAssertEqual(DirectoryViewStateStore(fileURL: fixture.file).state(for: fixture.root), customState)
    }

    private struct Fixture {
        let root: URL
        var file: URL { root.appendingPathComponent("view-state.plist") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Seeker-view-state-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
