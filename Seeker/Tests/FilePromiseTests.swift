import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Seeker

@MainActor
final class FilePromiseTests: XCTestCase {
    private struct EnvironmentProbe: NSViewRepresentable {
        @Environment(\.locale) var locale

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = .init(locale.identifier)
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            view.identifier = .init(locale.identifier)
        }
    }

    private final class FixtureExplorer: FileExplorerViewModel {
        override func navigateTo(_ url: URL) { currentURL = url }
        override func loadFiles() {}
    }

    private final class FixtureReceiver: NSFilePromiseReceiver {
        let sources: [URL]
        var receivingDirectory: URL?
        private var names: [String] = []

        init(sources: [URL]) {
            self.sources = sources
            super.init()
        }

        required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
            return nil
        }

        override var fileNames: [String] { names }

        override func receivePromisedFiles(
            atDestination destinationDir: URL, options: [AnyHashable: Any],
            operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void
        ) {
            receivingDirectory = destinationDir
            names = sources.map(\.lastPathComponent)
            for source in sources {
                let writer = FilePasteboardWriter(url: source)
                let destination = destinationDir.appendingPathComponent(source.lastPathComponent)
                writer.filePromiseProvider(writer, writePromiseTo: destination) { error in
                    reader(destination, error)
                }
            }
        }
    }

    func testWriterKeepsEagerLocalTypesAlongsideFilePromises() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("source.txt", "payload")
        let writer = FilePasteboardWriter(url: source)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(pasteboard.writeObjects([writer]))
        XCTAssertTrue(FileDropTargetView.hasFilePromises(pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .fileURL), source.absoluteString)
        XCTAssertEqual(pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String], [source.path])
        XCTAssertEqual(writer.writingOptions(forType: .fileURL, pasteboard: pasteboard), [])
        XCTAssertEqual(writer.filePromiseProvider(writer, fileNameForType: writer.fileType), "source.txt")
        XCTAssertFalse(writer.operationQueue(for: writer) === OperationQueue.main)
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])?.count, 1)
    }

    func testLegacyMultiFilePromiseCopiesFilesAndFoldersWithoutRemovingSources() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let file = try fixture.write("source/file.txt", "file bytes")
        let directory = try fixture.directory("source/tree")
        try fixture.directory("source/tree/empty")
        try fixture.write("source/tree/nested/child.txt", "child bytes")
        let destination = try fixture.directory("received")
        let receivers = [FixtureReceiver(sources: [file, directory])]

        var outcome: FilePromiseImport.Outcome?
        FilePromiseImport.receive(receivers, into: destination) { outcome = $0 }
        XCTAssertTrue(receivers.allSatisfy { $0.receivingDirectory == destination },
                      "Promises must be called in before the native drop callback returns")
        try await waitForWorkflow { outcome != nil }

        XCTAssertEqual(try XCTUnwrap(outcome).errors, [])
        XCTAssertEqual(Set(try XCTUnwrap(outcome).urls.map(\.lastPathComponent)), ["file.txt", "tree"])
        XCTAssertEqual(try fixture.contents("received/file.txt"), "file bytes")
        XCTAssertEqual(try fixture.contents("received/tree/nested/child.txt"), "child bytes")
        XCTAssertTrue(fixture.exists("received/tree/empty"))
        XCTAssertTrue(fixture.exists("source/file.txt"))
        XCTAssertTrue(fixture.exists("source/tree/nested/child.txt"))
    }

    func testMissingPromiseSourceReportsFailure() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let destination = try fixture.directory("received")
        let receivers = [FixtureReceiver(sources: [fixture.url("missing.txt")])]
        var outcome: FilePromiseImport.Outcome?
        FilePromiseImport.receive(receivers, into: destination) { outcome = $0 }
        try await waitForWorkflow { outcome != nil }
        XCTAssertTrue(try XCTUnwrap(outcome).urls.isEmpty)
        XCTAssertFalse(try XCTUnwrap(outcome).errors.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testPromiseImportUsesCopyUndoAndCleansStaging() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("source/file.txt", "payload")
        let destination = try fixture.directory("destination")
        let model = FixtureExplorer(url: destination)
        defer { model.cancelLoading() }
        let receivers = [FixtureReceiver(sources: [source])]
        let manager = FileOperationManager.shared
        let previousIDs = Set(manager.operations.map(\.id))
        model.receivePromisedFileDrop(receivers, to: destination)
        XCTAssertNotNil(model.fileMutationStatus)
        XCTAssertFalse(model.canUndo)
        try await waitForWorkflow { model.canUndo || model.showError }
        XCTAssertNil(model.errorMessage)
        guard case .copy(let destinations) = model.undoStack.last else {
            return XCTFail("Promised files must create a copy Undo action")
        }
        XCTAssertEqual(destinations, [destination.appendingPathComponent("file.txt")])
        XCTAssertEqual(try fixture.contents("destination/file.txt"), "payload")
        XCTAssertEqual(try fixture.contents("source/file.txt"), "payload")
        let operation = try XCTUnwrap(manager.operations.first { !previousIDs.contains($0.id) })
        let staging = try XCTUnwrap(operation.sourceURLs.first).deletingLastPathComponent()
        try await waitForWorkflow { !FileManager.default.fileExists(atPath: staging.path) }
    }

    func testEmptyPromiseDropReportsError() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let model = FixtureExplorer(url: fixture.root)
        defer { model.cancelLoading() }
        model.receivePromisedFileDrop([], to: fixture.root)
        try await waitForWorkflow { model.fileMutationStatus == nil }
        XCTAssertTrue(model.showError)
        XCTAssertTrue(model.errorMessage?.contains("readable file promise") == true)
        XCTAssertTrue(model.undoStack.isEmpty)
    }

    func testPartialPromiseFailureStillImportsSuccessfulFiles() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("source/good.txt", "payload")
        let destination = try fixture.directory("destination")
        let model = FixtureExplorer(url: destination)
        defer { model.cancelLoading() }
        let receiver = FixtureReceiver(sources: [source, fixture.url("missing.txt")])

        model.receivePromisedFileDrop([receiver], to: destination)
        try await waitForWorkflow { model.canUndo }

        XCTAssertTrue(model.showError)
        XCTAssertTrue(model.errorMessage?.contains("Could not receive some dropped files") == true)
        XCTAssertEqual(try fixture.contents("destination/good.txt"), "payload")
        XCTAssertTrue(fixture.exists("source/good.txt"))
        let staging = try XCTUnwrap(receiver.receivingDirectory)
        try await waitForWorkflow { !FileManager.default.fileExists(atPath: staging.path) }
    }

    func testCancelledQueuedPromiseImportCleansStagingWithoutAddingUndo() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let blockerSource = try fixture.write("source/blocker.txt", "blocker")
        let source = try fixture.write("source/promised.txt", "payload")
        let destination = try fixture.directory("destination")
        let model = FixtureExplorer(url: destination)
        defer { model.cancelLoading() }
        let manager = FileOperationManager.shared
        let wasPaused = manager.isPaused
        manager.isPaused = true
        defer { manager.isPaused = wasPaused }
        let blocker = try XCTUnwrap(manager.startCopy(sources: [blockerSource], to: destination) { _ in })
        defer { if !blocker.isFinished { blocker.cancel() } }
        let receiver = FixtureReceiver(sources: [source])
        model.receivePromisedFileDrop([receiver], to: destination)
        try await waitForWorkflow { model.fileMutationStatus == nil }
        let operation = try XCTUnwrap(manager.operations.last { $0.id != blocker.id && $0.isQueued })
        defer { if !operation.isFinished { operation.cancel() } }
        let staging = try XCTUnwrap(receiver.receivingDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(model.canUndo)

        operation.cancel()
        blocker.cancel()
        try await waitForWorkflow { operation.isFinished && !FileManager.default.fileExists(atPath: staging.path) }

        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(fixture.exists("destination/promised.txt"))
        XCTAssertTrue(fixture.exists("source/promised.txt"))
    }

    func testPromiseProviderDoesNotOverwriteExistingDestination() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("source.txt", "new")
        let destination = try fixture.write("existing.txt", "keep")
        let writer = FilePasteboardWriter(url: source)
        var calls = 0
        var failure: Error?

        writer.filePromiseProvider(writer, writePromiseTo: destination) { error in
            calls += 1
            failure = error
        }

        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(failure)
        XCTAssertEqual(try fixture.contents("existing.txt"), "keep")
        XCTAssertEqual(try fixture.contents("source.txt"), "new")
    }

    func testLegacyFilenamePasteboardImportsUsingNormalFilePipeline() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write("source/file.txt", "payload")
        let destination = try fixture.directory("destination")
        let model = FixtureExplorer(url: destination)
        defer { model.cancelLoading() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setPropertyList([source.path], forType: .init("NSFilenamesPboardType"))

        let providers = FileDropTargetView.itemProviders(from: pasteboard)
        XCTAssertEqual(providers.count, 1)
        model.receiveFileDrop(providers: providers, to: destination, isMove: false, copyInPlace: false)
        try await waitForWorkflow { model.canUndo || model.showError }

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try fixture.contents("destination/file.txt"), "payload")
        XCTAssertTrue(fixture.exists("source/file.txt"))
    }

    func testNativeTargetRegistersPromiseTypesAndPreservesOrdinaryClicks() throws {
        _ = NSApplication.shared
        let target = FileDropTargetView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let child = NSView(frame: target.bounds)
        target.addSubview(child)
        XCTAssertTrue(target.hitTest(NSPoint(x: 10, y: 10)) === child)
        for type in NSFilePromiseReceiver.readableDraggedTypes {
            XCTAssertTrue(target.registeredDraggedTypes.contains(.init(type)))
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("file:///tmp/file.txt", forType: .fileURL)
        target.allowsDrop = { false }
        XCTAssertEqual(target.operation(for: pasteboard), [])
        target.allowsDrop = { true }
        XCTAssertFalse(target.operation(for: pasteboard).isEmpty)
        let providers = FileDropTargetView.itemProviders(from: pasteboard)
        XCTAssertEqual(providers.count, 1)
        XCTAssertTrue(try XCTUnwrap(providers.first).hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
    }

    func testNativeWrapperFillsBrowserAreaAndForwardsEnvironment() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: FileDropTarget(
            content: EnvironmentProbe(), allowsDrop: { true }, onDrop: { _ in }
        )
        .environment(\.locale, Locale(identifier: "fr_FR"))
        .frame(width: 640, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(host)
        let target = try XCTUnwrap(views.first { $0 is FileDropTargetView })
        XCTAssertEqual(target.frame.size, NSSize(width: 640, height: 480))
        XCTAssertTrue(views.contains { $0.identifier?.rawValue == "fr_FR" })
    }

    func testNativeImagePasteboardStillImportsBrowserImageData() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanup() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)
        var completed = false

        BrowserDropImporter.importProviders(
            FileDropTargetView.itemProviders(from: pasteboard), into: fixture.root
        ) { completed = true }
        try await waitForWorkflow { completed }

        let files = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), tiff)
    }
}
