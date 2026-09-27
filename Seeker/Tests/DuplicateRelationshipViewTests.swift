import AppKit
import SwiftUI
import XCTest
@testable import Seeker

@MainActor
final class DuplicateRelationshipViewTests: XCTestCase {
    func testLocateWaitsForDirectoryExpansionAndTargetsTheRequestedFile() async throws {
        _ = NSApplication.shared
        let urls = (0..<30).map { URL(fileURLWithPath: "/A/file\($0).jpg") }
        let group = DuplicateFinder.Group(fileSize: 1024, urls: urls)
        let directory = try XCTUnwrap(DuplicateResultDirectory.grouped([group]).first)
        let target = urls[25]
        var ready: [URL] = []
        var selection = Set(urls.dropFirst())
        let originalSelection = selection
        func row(expanded: Bool) -> DuplicateDirectoryRow {
            DuplicateDirectoryRow(
                directory: directory, isExpanded: expanded,
                toDelete: Binding(get: { selection }, set: { selection = $0 }),
                focusedURL: .constant(target), selectedGroupID: group.id, locateURL: target,
                onLocate: { _ in }, onLocateReady: { ready.append($0) },
                onToggleExpand: {}, onSelect: { _ in }
            )
        }
        let host = NSHostingView(rootView: row(expanded: false))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(ready.isEmpty)
        host.rootView = row(expanded: true)
        let deadline = ContinuousClock.now + .seconds(3)
        while ready.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(ready, [target])
        XCTAssertEqual(selection, originalSelection)
    }

    func testCopiesPanelHasBoundedLayoutWithManyLongPaths() throws {
        _ = NSApplication.shared
        let urls = (0..<100).map {
            URL(fileURLWithPath: "/Volumes/Archive/Long folder name/Another long folder name/Folder \($0)/cover.jpg")
        }
        let group = DuplicateFinder.Group(fileSize: 1024, urls: urls)
        let file = try XCTUnwrap(DuplicateResultDirectory.grouped([group]).first?.files.first)
        let host = NSHostingView(rootView: DuplicateCopiesView(
            file: file, toDelete: Set(urls.dropFirst()), onLocate: { _ in }
        ))
        XCTAssertEqual(host.fittingSize.width, 480)
        XCTAssertEqual(host.fittingSize.height, 440)
    }

    func testFileRowFitsMinimumResultPaneWithoutChangingSelection() throws {
        _ = NSApplication.shared
        let keep = URL(fileURLWithPath: "/A/A very long file name to exercise row truncation.jpg")
        let copy = URL(fileURLWithPath: "/B/renamed.jpg")
        let group = DuplicateFinder.Group(fileSize: 1024, urls: [keep, copy])
        let file = try XCTUnwrap(DuplicateResultDirectory.grouped([group]).first?.files.first)
        var selection: Set<URL> = [copy]
        for (focused, related) in [(true, false), (false, true), (false, false)] {
            let host = NSHostingView(rootView: DuplicateFileRow(
                file: file,
                toDelete: Binding(get: { selection }, set: { selection = $0 }),
                isFocused: focused, isRelated: related,
                onSelect: {}, onLocate: { _ in }
            ).frame(width: 344))
            XCTAssertEqual(host.fittingSize.width, 344)
            XCTAssertLessThan(host.fittingSize.height, 75)
            XCTAssertEqual(selection, [copy])
        }
    }
}
