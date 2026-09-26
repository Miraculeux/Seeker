import Foundation
import XCTest
@testable import Seeker

final class TrashOperationTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testCommandBackspaceDefaultsToMoveToTrash() {
        let shortcut = ShortcutAction.moveToTrash.defaultShortcut
        XCTAssertEqual(shortcut.key, "⌫")
        XCTAssertEqual(shortcut.modifiers, [.command])
    }

    @MainActor
    func testTrashSelectionPreservesFilesAndFoldersAndUndoRestoresThem() async throws {
        let fm = FileManager.default
        // Keep the fixture on the repository's volume to exercise external-drive Trash.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".trash-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("seeker-test-file-\(UUID().uuidString).txt")
        let folder = root.appendingPathComponent("seeker-test-folder-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("child.txt")
        let payload = Data("Disposable Seeker Trash regression fixture".utf8)
        try payload.write(to: file)
        try payload.write(to: child)

        let service = TrashRestoreService(recordsDirectory: root.appendingPathComponent("origins"))
        let model = FileExplorerViewModel(url: root, trashService: service)
        defer { model.cancelLoading() }
        model.cancelLoading()
        model.files = [FileItem(url: file), FileItem(url: folder)]
        model.selectedFileIDs = Set(model.files.map(\.id))
        model.trashSelected()
        try await waitForMutation(model)
        XCTAssertNil(model.errorMessage)
        guard case .trash(let originals, let trashURLs) = try XCTUnwrap(model.undoStack.last) else {
            return XCTFail("Move to Trash must record recoverable destinations")
        }
        defer {
            for url in trashURLs where fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
        XCTAssertEqual(Set(originals), Set([file, folder]))
        XCTAssertEqual(trashURLs.count, 2)
        let listing = TrashDiagnostics.listing()
        for trashed in trashURLs {
            XCTAssertTrue(listing.urls.contains { $0.standardizedFileURL.path == trashed.standardizedFileURL.path },
                          "The aggregate Trash list must include files on the source volume")
        }
        let trashView = FileExplorerViewModel(
            url: fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        )
        defer { trashView.cancelLoading() }
        let expectedPaths = Set(trashURLs.map(\.standardizedFileURL.path))
        let deadline = ContinuousClock.now + .seconds(15)
        while !expectedPaths.isSubset(of: Set(trashView.files.map(\.url.standardizedFileURL.path))),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(expectedPaths.isSubset(of: Set(trashView.files.map(\.url.standardizedFileURL.path))),
                      "The Trash view must display external items even if Finder omits them")
        for (original, trashed) in zip(originals, trashURLs) {
            XCTAssertFalse(fm.fileExists(atPath: original.path))
            XCTAssertTrue(fm.fileExists(atPath: trashed.path))
            XCTAssertTrue(trashed.pathComponents.contains(".Trashes") || trashed.pathComponents.contains(".Trash"))
            let storedPayload = original == folder ? trashed.appendingPathComponent("child.txt") : trashed
            XCTAssertEqual(try Data(contentsOf: storedPayload), payload)
            print("Verified recoverable Trash destination: \(trashed.path)")
        }
        XCTAssertTrue(model.canUndo)
        model.undo()
        try await waitForMutation(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: file), payload)
        XCTAssertEqual(try Data(contentsOf: child), payload)
        XCTAssertTrue(trashURLs.allSatisfy { !fm.fileExists(atPath: $0.path) })
    }

    func testTrashListingCombinesVolumesAndRefreshesWithoutHomeChanges() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SeekerTrashListing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let external = root.appendingPathComponent("external")
        let absent = root.appendingPathComponent("no-trash-yet")
        try fm.createDirectory(at: home, withIntermediateDirectories: false)
        try fm.createDirectory(at: external, withIntermediateDirectories: false)
        let homeFile = home.appendingPathComponent("same.txt")
        let externalFile = external.appendingPathComponent("same.txt")
        let hiddenFile = external.appendingPathComponent(".hidden")
        try Data("home".utf8).write(to: homeFile)
        let roots = [home, external, absent, external]
        XCTAssertEqual(TrashDiagnostics.listing(roots: roots).urls.map(\.lastPathComponent), ["same.txt"])

        try Data("external".utf8).write(to: externalFile)
        try Data("hidden".utf8).write(to: hiddenFile)
        let listing = TrashDiagnostics.listing(roots: roots)
        XCTAssertTrue(listing.errors.isEmpty)
        XCTAssertEqual(Set(listing.urls.map(\.standardizedFileURL.path)),
                       Set([homeFile, externalFile, hiddenFile].map { $0.resolvingSymlinksInPath().path }))
        XCTAssertEqual(listing.urls.count, 3)
        try fm.removeItem(at: externalFile)
        XCTAssertEqual(TrashDiagnostics.listing(roots: roots).urls.count, 2)
    }

    func testTrashListingReportsUnreadableRootsWithoutHidingReadableItems() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SeekerTrashErrors-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-directory")
        try Data("preserved".utf8).write(to: file)
        let listing = TrashDiagnostics.listing(roots: [file, root])
        XCTAssertEqual(listing.urls.map(\.lastPathComponent), ["not-a-directory"])
        XCTAssertEqual(listing.errors.count, 1)
        XCTAssertTrue(listing.errors[0].contains(file.path))
    }

    @MainActor
    func testTrashTabReloadsForExternalDirectoryChanges() {
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let trash = ReloadCountingExplorer(url: homeTrash)
        let unrelated = ReloadCountingExplorer(url: FileManager.default.temporaryDirectory)
        let trashCount = trash.loadCount
        let unrelatedCount = unrelated.loadCount
        NotificationCenter.default.post(
            name: .filesDidChange,
            object: nil,
            userInfo: [FileExplorerViewModel.affectedDirKey: URL(fileURLWithPath: "/Volumes/Example/Temp")]
        )
        XCTAssertEqual(trash.loadCount, trashCount + 1)
        XCTAssertEqual(unrelated.loadCount, unrelatedCount)
    }

    func testTrashCacheCanBeInvalidatedWithoutHomeTimestampChange() {
        let cache = TrashCache()
        let date = Date()
        cache.set([], mtime: date)
        XCTAssertNotNil(cache.get(mtime: date))
        cache.invalidate()
        XCTAssertNil(cache.get(mtime: date))
    }

    @MainActor
    private func waitForMutation(_ model: FileExplorerViewModel) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while model.fileMutationStatus != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(model.fileMutationStatus, "File mutation timed out")
    }

    @MainActor
    private final class ReloadCountingExplorer: FileExplorerViewModel {
        var loadCount = 0

        override func loadFiles() {
            loadCount += 1
        }
    }
}
