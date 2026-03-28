import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var spaceMonitor: Any?
    var doubleClickMonitor: Any?
    var mouseDownMonitor: Any?
    let quickLookPanel = QuickLookPanelController()
    weak var appState: AppState?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
               let iconImage = NSImage(contentsOf: iconURL) {
                NSApplication.shared.applicationIconImage = iconImage
            }
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            appState?.saveCurrentLocations()
        }
    }

    func installSpaceMonitor(appState: AppState) {
        self.appState = appState
        AppDelegate.shared = self

        if spaceMonitor == nil {
            // Space key → Quick Look, Return key → Open item
            spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Check if user is typing in a text field (search/filter/rename)
                let isTypingInTextField: Bool = {
                    guard let firstResponder = event.window?.value(forKey: "firstResponder") as? NSResponder else {
                        return false
                    }
                    // NSTextView field editors used by focused text fields
                    if let textView = firstResponder as? NSTextView,
                       textView.isFieldEditor {
                        // Only block if the parent text field is actually focused for editing
                        // (has selected text or non-empty string, or it's a search/filter field)
                        if let selectedRange = textView.selectedRanges.first as? NSRange,
                           selectedRange.length > 0 {
                            return true
                        }
                        if textView.string.count > 0 {
                            return true
                        }
                        return false
                    }
                    if firstResponder is NSTextField {
                        return true
                    }
                    return false
                }()
                if isTypingInTextField {
                    return event
                }
                if event.keyCode == 49, !event.isARepeat {
                    // Space → Quick Look
                    if let delegate = AppDelegate.shared,
                       let url = delegate.appState?.activeExplorer.selectedFile?.url {
                        delegate.quickLookPanel.togglePreview(for: url)
                    }
                    return nil // consume space so List doesn't scroll/deselect
                } else if event.keyCode == 36, !event.isARepeat {
                    // Return → Open selected item
                    if let delegate = AppDelegate.shared,
                       let file = delegate.appState?.activeExplorer.selectedFile {
                        delegate.appState?.activeExplorer.openItem(file)
                    }
                } else if event.keyCode == 8, event.modifierFlags.contains(.command) {
                    // Cmd+C → Copy selected files
                    if let delegate = AppDelegate.shared {
                        delegate.appState?.activeExplorer.copySelected()
                    }
                    return nil
                } else if event.keyCode == 9, event.modifierFlags.contains(.command), event.modifierFlags.contains(.option) {
                    // Cmd+Option+V → Move (paste as move)
                    if let delegate = AppDelegate.shared {
                        delegate.appState?.activeExplorer.pasteMoving()
                    }
                    return nil
                } else if event.keyCode == 9, event.modifierFlags.contains(.command) {
                    // Cmd+V → Paste files
                    if let delegate = AppDelegate.shared {
                        delegate.appState?.activeExplorer.paste()
                    }
                    return nil
                } else if event.keyCode == 125 || event.keyCode == 126 {
                    // Arrow Down (125) / Arrow Up (126) → navigate selection
                    if let delegate = AppDelegate.shared,
                       let vm = delegate.appState?.activeExplorer {
                        let files = vm.files
                        guard !files.isEmpty else { return event }
                        let currentIndex = files.firstIndex(where: { $0 == vm.selectedFile })
                        let newIndex: Int
                        if event.keyCode == 125 { // Down
                            newIndex = (currentIndex == nil) ? 0 : min((currentIndex! + 1), files.count - 1)
                        } else { // Up
                            newIndex = (currentIndex == nil) ? 0 : max((currentIndex! - 1), 0)
                        }
                        vm.selectedFile = files[newIndex]
                    }
                    return nil // consume arrow keys so the old panel's List doesn't also move
                }
                return event
            }
        }

        if doubleClickMonitor == nil {
            // Double-click → Open item (only on actual list/collection rows)
            doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                guard event.clickCount == 2,
                      let delegate = AppDelegate.shared,
                      let state = delegate.appState,
                      let window = event.window else { return event }

                // Only proceed if the click is on a table row (file list row)
                let windowPoint = event.locationInWindow
                if let hitView = window.contentView?.hitTest(windowPoint) {
                    var isOnRow = false
                    var view: NSView? = hitView
                    while let v = view {
                        if v is NSTableRowView || v is NSCollectionView {
                            isOnRow = true
                            break
                        }
                        view = v.superview
                    }
                    guard isOnRow else { return event }
                }

                let screenPoint = window.convertPoint(toScreen: windowPoint)
                let windowFrame = window.frame
                let flippedY = windowFrame.maxY - screenPoint.y
                let globalPoint = CGPoint(x: screenPoint.x - windowFrame.minX, y: flippedY)
                // Only trigger if click is inside a pane
                guard state.leftPaneFrame.contains(globalPoint) ||
                      state.rightPaneFrame.contains(globalPoint) else { return event }
                if let file = state.activeExplorer.selectedFile {
                    state.activeExplorer.openItem(file)
                }
                return event
            }
        }

        if mouseDownMonitor == nil {
            // MouseDown → detect which pane was clicked to set activePane
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                guard let delegate = AppDelegate.shared,
                      let state = delegate.appState,
                      let window = event.window else { return event }
                let windowPoint = event.locationInWindow
                let screenPoint = window.convertPoint(toScreen: windowPoint)
                let windowFrame = window.frame
                let flippedY = windowFrame.maxY - screenPoint.y
                let globalPoint = CGPoint(x: screenPoint.x - windowFrame.minX, y: flippedY)

                if state.leftPaneFrame.contains(globalPoint) && state.activePane != .left {
                    DispatchQueue.main.async { state.activePane = .left }
                } else if state.rightPaneFrame.contains(globalPoint) && state.activePane != .right {
                    DispatchQueue.main.async { state.activePane = .right }
                }
                return event
            }
        }
    }

    func updateQuickLookIfVisible(url: URL) {
        if quickLookPanel.isVisible {
            quickLookPanel.updatePreview(for: url)
        }
    }
}

@main
struct SeekerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onAppear {
                    appDelegate.installSpaceMonitor(appState: appState)
                    appState.restoreLastLocations()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    appState.saveCurrentLocations()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.saveCurrentLocations()
                }
                .onReceive(NotificationCenter.default.publisher(for: .explorerDidNavigate)) { _ in
                    appState.saveCurrentLocations()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 700)
        .commands {
            // MARK: - View Menu
            CommandGroup(after: .sidebar) {
                Button("Toggle Favorites Sidebar") {
                    withAnimation { appState.showFavorites.toggle() }
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Toggle Dual Pane") {
                    withAnimation { appState.showDualPane.toggle() }
                }
                .keyboardShortcut("u", modifiers: [.command])

                Divider()

                Button("List View") {
                    appState.activeExplorer.viewMode = .list
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Icon View") {
                    appState.activeExplorer.viewMode = .icons
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Column View") {
                    appState.activeExplorer.viewMode = .columns
                }
                .keyboardShortcut("3", modifiers: [.command])
            }

            // MARK: - File Operations (Edit menu)
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("New Folder") {
                    appState.activeExplorer.createNewFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New File") {
                    appState.activeExplorer.createNewFile()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Divider()

                Button("Duplicate") {
                    appState.activeExplorer.duplicateSelected()
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Move to Trash") {
                    appState.activeExplorer.trashSelected()
                }
                .keyboardShortcut(.delete, modifiers: [.command])

                Button("Rename") {
                    if let file = appState.activeExplorer.selectedFile {
                        appState.activeExplorer.beginRename(file)
                    }
                }

                Divider()

                Button("Copy to Other Pane") {
                    appState.copyToOtherPane()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Move to Other Pane") {
                    appState.moveToOtherPane()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            // MARK: - Go Menu
            CommandMenu("Go") {
                Button("Back") {
                    appState.activeExplorer.goBack()
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Forward") {
                    appState.activeExplorer.goForward()
                }
                .keyboardShortcut("]", modifiers: [.command])

                Button("Enclosing Folder") {
                    appState.activeExplorer.goUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Divider()

                Button("Home") {
                    appState.activeExplorer.navigateTo(
                        FileManager.default.homeDirectoryForCurrentUser
                    )
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("Desktop") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                    appState.activeExplorer.navigateTo(url)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Downloads") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                    appState.activeExplorer.navigateTo(url)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Documents") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
                    appState.activeExplorer.navigateTo(url)
                }

                Button("Applications") {
                    appState.activeExplorer.navigateTo(URL(fileURLWithPath: "/Applications"))
                }

                Divider()

                Button("Go to Folder…") {
                    // TODO: implement Go to Folder sheet
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            // MARK: - Tabs
            CommandMenu("Tab") {
                Button("New Tab") {
                    let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
                    pane.addTab()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("Close Tab") {
                    let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
                    pane.closeTab(at: pane.activeTabIndex)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            // MARK: - Refresh
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    appState.activeExplorer.loadFiles()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
