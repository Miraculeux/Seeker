import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
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

                Button("Toggle Sync Browsing") {
                    appState.syncBrowsing.toggle()
                }
                .keyboardShortcut("y", modifiers: [.command])

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
    }
}
