import AppKit
import XCTest
@testable import Seeker

@MainActor
final class FileDragCatcherTests: XCTestCase {
    func testInactiveWindowAcceptsFirstClick() throws {
        let (window, view) = makeWindow()
        defer { window.close() }

        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(view.acceptsFirstMouse(for: try event(.leftMouseDown, in: window)))
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testRenameDoesNotAcceptFirstClick() throws {
        let (window, view) = makeWindow()
        defer { window.close() }
        view.isDragEnabled = false

        XCTAssertFalse(view.acceptsFirstMouse(for: try event(.leftMouseDown, in: window)))
    }

    func testFirstDoubleClickDeliversSelectionThenOpenWithoutDragging() throws {
        let (window, view) = makeWindow()
        defer { window.close() }
        var clicks: [Int] = []
        var dragRequests = 0
        view.clickHandler = { command, shift, count in
            XCTAssertFalse(command)
            XCTAssertFalse(shift)
            clicks.append(count)
        }
        view.urlsProvider = {
            dragRequests += 1
            return []
        }

        for count in 1...2 {
            let down = try event(.leftMouseDown, in: window, clickCount: count)
            XCTAssertTrue(view.acceptsFirstMouse(for: down))
            NSApp.postEvent(try event(.leftMouseUp, in: window, clickCount: count), atStart: true)
            view.mouseDown(with: down)
        }

        XCTAssertEqual(clicks, [1, 2])
        XCTAssertEqual(dragRequests, 0)
    }

    func testFirstClickOnDisclosureTogglesInsteadOfSelecting() throws {
        let (window, view) = makeWindow()
        defer { window.close() }
        view.chevronRange = 4...26
        var toggles = 0
        view.toggleExpandHandler = { toggles += 1 }
        view.clickHandler = { _, _, _ in
            XCTFail("Disclosure click must not select or open the row")
        }
        let down = try event(.leftMouseDown, in: window)

        XCTAssertTrue(view.acceptsFirstMouse(for: down))
        NSApp.postEvent(try event(.leftMouseUp, in: window), atStart: true)
        view.mouseDown(with: down)

        XCTAssertEqual(toggles, 1)
    }

    private func makeWindow() -> (NSWindow, FileDragNSView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = FileDragNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        window.contentView = view
        return (window, view)
    }

    private func event(
        _ type: NSEvent.EventType,
        in window: NSWindow,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 12, y: 20),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: clickCount,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        ))
    }
}
