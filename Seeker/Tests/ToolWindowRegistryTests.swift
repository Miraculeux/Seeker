import AppKit
import SwiftUI
import XCTest
@testable import Seeker

@MainActor
final class ToolWindowRegistryTests: XCTestCase {
    func testRegistrationSeparatesMainWindowsAndUpdatesInPlace() {
        let registry = ToolWindowRegistry()
        let first = makeWindow()
        let second = makeWindow()
        let third = makeWindow()
        defer { first.close(); second.close(); third.close() }
        let source = UUID()
        let otherSource = UUID()
        let owner = UUID()
        let initial = URL(fileURLWithPath: "/Volumes/Passport")
        let updated = URL(fileURLWithPath: "/Volumes/Archive")
        registry.register(window: first, ownerID: owner, sourceWindowID: source,
                          kind: .duplicates, urls: [initial])
        registry.register(window: second, ownerID: UUID(), sourceWindowID: source,
                          kind: .duplicates, urls: [initial])
        registry.register(window: third, ownerID: UUID(), sourceWindowID: otherSource,
                          kind: .search, urls: [initial])
        XCTAssertEqual(registry.windows(for: source).count, 2)
        XCTAssertEqual(registry.windows(for: otherSource).count, 1)
        XCTAssertEqual(registry.windows(for: UUID()).count, 0)
        registry.register(window: first, ownerID: owner, sourceWindowID: source,
                          kind: .duplicates, urls: [updated, initial])
        let entries = registry.windows(for: source)
        XCTAssertEqual(entries.map(\.id), [ObjectIdentifier(first), ObjectIdentifier(second)])
        XCTAssertEqual(entries.first?.label, "Find Duplicates \u{00B7} Archive \u{00B7} Passport")
        XCTAssertTrue(entries.first?.help.contains(updated.path) == true)
    }

    func testClosingRemovesOnlyTheClosedWindow() {
        let registry = ToolWindowRegistry()
        let first = makeWindow()
        let second = makeWindow()
        defer { second.close() }
        let source = UUID()
        for window in [first, second] {
            registry.register(window: window, ownerID: UUID(), sourceWindowID: source,
                              kind: .compare, urls: [])
        }
        first.close()
        XCTAssertEqual(registry.windows(for: source).map(\.id), [ObjectIdentifier(second)])
        second.close()
        XCTAssertTrue(registry.windows(for: source).isEmpty)
    }

    func testLateUnregistrationDoesNotRemoveReplacementRegistration() {
        let registry = ToolWindowRegistry()
        let window = makeWindow()
        defer { window.close() }
        let oldOwner = UUID()
        let newOwner = UUID()
        let source = UUID()
        registry.register(window: window, ownerID: oldOwner, sourceWindowID: source, kind: .sync, urls: [])
        registry.register(window: window, ownerID: newOwner, sourceWindowID: source, kind: .sync, urls: [])
        registry.unregister(ownerID: oldOwner)
        XCTAssertEqual(registry.windows(for: source).count, 1)
        registry.unregister(ownerID: newOwner)
        XCTAssertTrue(registry.windows(for: source).isEmpty)
    }

    func testRegistryDoesNotRetainWindows() {
        let registry = ToolWindowRegistry()
        let source = UUID()
        weak var released: NSWindow?
        autoreleasepool {
            let window = makeWindow()
            released = window
            registry.register(window: window, ownerID: UUID(), sourceWindowID: source, kind: .search, urls: [])
        }
        XCTAssertNil(released)
        XCTAssertTrue(registry.windows(for: source).isEmpty)
    }

    func testActivationRestoresTheSameWindowAndContent() async throws {
        let registry = ToolWindowRegistry()
        let window = makeWindow()
        let main = makeWindow()
        defer { window.close(); main.close() }
        let content = NSView()
        window.contentView = content
        let source = UUID()
        registry.register(window: window, ownerID: UUID(), sourceWindowID: source, kind: .duplicates, urls: [])
        window.makeKeyAndOrderFront(nil)
        main.makeKeyAndOrderFront(nil)
        XCTAssertTrue(NSApp.orderedWindows.first === main)
        registry.activate(ObjectIdentifier(window))
        XCTAssertTrue(window.isVisible)
        // The command-line XCTest host cannot become the active app. Verify
        // real front-to-back window order rather than key status in that host.
        XCTAssertTrue(NSApp.orderedWindows.first === window)
        XCTAssertTrue(window.contentView === content)
        window.miniaturize(nil)
        try await waitUntil { window.isMiniaturized }
        XCTAssertEqual(registry.windows(for: source).count, 1)
        registry.activate(ObjectIdentifier(window))
        try await waitUntil { !window.isMiniaturized && NSApp.orderedWindows.first === window }
        XCTAssertTrue(window.contentView === content)
        XCTAssertEqual(registry.windows(for: source).count, 1)
    }

    func testSwiftUIRegistrationUpdatesAndDoesNotResurrectClosedWindow() async throws {
        let window = makeWindow()
        let source = UUID()
        let initial = URL(fileURLWithPath: "/Volumes/Passport")
        let updated = URL(fileURLWithPath: "/Volumes/Archive")
        let host = NSHostingView(rootView: ToolWindowRegistrationView(
            sourceWindowID: source, kind: .duplicates, urls: [initial]
        ))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await waitUntil { ToolWindowRegistry.shared.windows(for: source).first?.urls == [initial] }
        host.rootView = ToolWindowRegistrationView(sourceWindowID: source, kind: .duplicates, urls: [updated])
        try await waitUntil { ToolWindowRegistry.shared.windows(for: source).first?.urls == [updated] }
        window.close()
        XCTAssertTrue(ToolWindowRegistry.shared.windows(for: source).isEmpty)
        host.rootView = ToolWindowRegistrationView(sourceWindowID: source, kind: .duplicates, urls: [initial])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(ToolWindowRegistry.shared.windows(for: source).isEmpty)
    }

    func testAllToolSymbolsAndEmptyContextLabels() {
        let registry = ToolWindowRegistry()
        let window = makeWindow()
        defer { window.close() }
        let source = UUID()
        for kind in ToolWindowKind.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil))
            registry.register(window: window, ownerID: UUID(), sourceWindowID: source, kind: kind, urls: [])
            XCTAssertEqual(registry.windows(for: source).first?.label, kind.title)
        }
    }

    func testDetachingRegistrationRemovesItsLabel() async throws {
        let window = makeWindow()
        defer { window.close() }
        let source = UUID()
        let host = NSHostingView(rootView: ToolWindowRegistrationView(
            sourceWindowID: source, kind: .search, urls: []
        ))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { ToolWindowRegistry.shared.windows(for: source).count == 1 }
        window.contentView = NSView()
        try await waitUntil { ToolWindowRegistry.shared.windows(for: source).isEmpty }
        withExtendedLifetime(host) {}
    }

    func testBarHasCompactHeightAndDisappearsAfterLastWindowCloses() async throws {
        let source = UUID()
        let host = NSHostingView(rootView: ToolWindowBar(sourceWindowID: source).frame(width: 900))
        XCTAssertLessThan(host.fittingSize.height, 1)
        let windows = (0..<12).map { _ in makeWindow() }
        defer { windows.forEach { $0.close() } }
        for (index, window) in windows.enumerated() {
            ToolWindowRegistry.shared.register(
                window: window, ownerID: UUID(), sourceWindowID: source, kind: .duplicates,
                urls: [URL(fileURLWithPath: "/Volumes/Folder \(index)")]
            )
        }
        try await waitUntil { host.fittingSize.height >= 36 }
        XCTAssertLessThan(host.fittingSize.height, 40)
        XCTAssertEqual(host.fittingSize.width, 900)
        windows.forEach { $0.close() }
        try await waitUntil { host.fittingSize.height < 1 }
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
