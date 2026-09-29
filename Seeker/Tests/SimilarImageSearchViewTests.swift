import AppKit
import SwiftUI
import XCTest
@testable import Seeker

final class SimilarImageSearchViewTests: XCTestCase {
    @MainActor
    func testViewUsesExactlyTwoSideBySidePanels() {
        _ = NSApplication.shared
        let request = SimilarImageSearchRequest(
            referenceURL: URL(fileURLWithPath: "/tmp/reference.png"),
            targetDirectory: URL(fileURLWithPath: "/tmp")
        )
        let host = NSHostingView(rootView: SimilarImageSearchView(request: request)
            .frame(width: 1120, height: 680))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1120, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        let splits = splitViews(in: host)
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits.first?.arrangedSubviews.count, 2)
        XCTAssertEqual(splits.first?.isVertical, true)
    }

    @MainActor
    func testSharedDirectoryTreeRevealsInitialTarget() async throws {
        let parent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("directory-tree-\(UUID().uuidString)", isDirectory: true)
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let model = SearchDirectoryTreeModel()
        await model.reveal(target)

        XCTAssertTrue(model.expandedPaths.contains(parent.standardizedFileURL.path))
        XCTAssertTrue(model.rows.contains {
            $0.item.url.standardizedFileURL == target.standardizedFileURL
        })
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap { splitViews(in: $0) }
    }
}
