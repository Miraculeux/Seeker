import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import Seeker

final class DuplicateComparisonTests: XCTestCase {
    func testSameDirectoryCopiesExcludeSelectedFileAndDoNotExpandRecursively() {
        let a = URL(fileURLWithPath: "/Album/a.flac")
        let b = URL(fileURLWithPath: "/Album/b.flac")
        let group = DuplicateFinder.Group(fileSize: 100, urls: [a, b])
        for _ in 0..<100 {
            let targets = DuplicateComparisonTargets(selected: a, groups: [group])
            XCTAssertEqual(targets.selected, a)
            XCTAssertEqual(targets.copies, [b])
            XCTAssertEqual(targets.comparison(preferred: a), b)
        }
        let reversed = DuplicateComparisonTargets(selected: b, groups: [group])
        XCTAssertEqual(reversed.copies, [a])
    }

    func testSelectorContainsOnlyOtherMembersOfContentGroup() {
        let a = URL(fileURLWithPath: "/A/cover.jpg")
        let b = URL(fileURLWithPath: "/B/renamed.jpg")
        let c = URL(fileURLWithPath: "/C/cover.jpg")
        let unrelated = URL(fileURLWithPath: "/D/cover.jpg")
        let groups = [
            DuplicateFinder.Group(fileSize: 100, urls: [a, b, c]),
            DuplicateFinder.Group(fileSize: 100, urls: [unrelated, URL(fileURLWithPath: "/E/cover.jpg")]),
        ]
        let targets = DuplicateComparisonTargets(selected: a, groups: groups)
        XCTAssertEqual(targets.copies, [b, c])
        XCTAssertEqual(targets.comparison(preferred: nil), b)
        XCTAssertEqual(targets.comparison(preferred: c), c)
        XCTAssertEqual(targets.comparison(preferred: unrelated), b)
        XCTAssertEqual(groups[0].urls, [a, b, c])
    }

    func testDeletionReconcilesComparisonAndClearsRemovedSelection() throws {
        let a = URL(fileURLWithPath: "/A/a")
        let b = URL(fileURLWithPath: "/B/b")
        let c = URL(fileURLWithPath: "/C/c")
        let group = DuplicateFinder.Group(fileSize: 100, urls: [a, b, c])
        let remaining = try XCTUnwrap(group.removing([b]))
        let targets = DuplicateComparisonTargets(selected: a, groups: [remaining])
        XCTAssertEqual(targets.comparison(preferred: b), c)
        let deletedSelection = DuplicateComparisonTargets(selected: b, groups: [remaining])
        XCTAssertNil(deletedSelection.selected)
        XCTAssertTrue(deletedSelection.copies.isEmpty)
        XCTAssertNil(deletedSelection.comparison(preferred: c))
        XCTAssertNil(DuplicateComparisonTargets(selected: a, groups: []).selected)
        XCTAssertTrue(DuplicateComparisonTargets(selected: nil, groups: [group]).copies.isEmpty)
    }

    func testNormalizedPathsNeverSelectTheSameFileAsItsOwnCopy() {
        let a = URL(fileURLWithPath: "/A/cover.jpg")
        let alias = URL(fileURLWithPath: "/A/./cover.jpg")
        let b = URL(fileURLWithPath: "/B/cover.jpg")
        let group = DuplicateFinder.Group(fileSize: 100, urls: [a, alias, b, b])
        let targets = DuplicateComparisonTargets(selected: alias, groups: [group])
        XCTAssertEqual(targets.copies, [b])
    }

    func testChangingLeftSelectionReplacesComparisonCandidates() {
        let a = URL(fileURLWithPath: "/A/a")
        let b = URL(fileURLWithPath: "/A/b")
        let c = URL(fileURLWithPath: "/C/c")
        let d = URL(fileURLWithPath: "/D/d")
        let groups = [
            DuplicateFinder.Group(fileSize: 100, urls: [a, b]),
            DuplicateFinder.Group(fileSize: 200, urls: [c, d]),
        ]
        let original = DuplicateComparisonTargets(selected: a, groups: groups)
        let changed = DuplicateComparisonTargets(selected: c, groups: groups)
        XCTAssertEqual(changed.selected, c)
        XCTAssertEqual(changed.copies, [d])
        XCTAssertEqual(changed.comparison(preferred: original.comparison(preferred: nil)), d)
    }

    @MainActor
    func testEmptyComparisonStillUsesExactlyTwoResizablePanes() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: DuplicateComparisonPanels(
            targets: DuplicateComparisonTargets(selected: nil, groups: []),
            onDeleted: { _ in XCTFail("Layout must not delete files") }
        ).frame(width: 380, height: 420))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 380, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func splitViews(in view: NSView) -> [NSSplitView] {
            (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap { splitViews(in: $0) }
        }
        let splits = splitViews(in: host)
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits.first?.arrangedSubviews.count, 2)
        XCTAssertEqual(splits.first?.isVertical, false)
        XCTAssertEqual(host.fittingSize.width, 380)
        XCTAssertEqual(host.fittingSize.height, 420)
    }
}
