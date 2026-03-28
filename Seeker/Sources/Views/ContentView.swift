import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState

    private var toolbarSearchBinding: Binding<String> {
        Binding(
            get: { appState.activeExplorer.searchText },
            set: { appState.activeExplorer.searchText = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // ForkLift-style main toolbar
            mainToolbar
            Divider()

            // Pane area
            HStack(spacing: 0) {
                // Favorites sidebar (slides in)
                if appState.showFavorites {
                    SidebarView()
                        .frame(width: 140)
                        .transition(.move(edge: .leading))
                    Divider()
                }

                // Dual pane (or single pane)
                if appState.showDualPane {
                    HSplitView {
                        PaneView(pane: appState.leftPane, side: .left)
                            .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)

                        PaneView(pane: appState.rightPane, side: .right)
                            .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PaneView(pane: appState.leftPane, side: .left)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Info panel (rightmost)
                if appState.showInfoPanel {
                    Divider()
                    FileInfoView()
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 550, maxHeight: .infinity)
    }

// MARK: - Modern Toolbar

    private var mainToolbar: some View {
        HStack(spacing: 0) {
            // Left group: sidebar + navigation
            HStack(spacing: 2) {
                ToolbarBtn(icon: "sidebar.left", isActive: appState.showFavorites, tip: "Favorites") {
                    withAnimation(.easeInOut(duration: 0.15)) { appState.showFavorites.toggle() }
                }

                ToolbarSep()

                ToolbarBtn(icon: "chevron.left", tip: "Back") {
                    appState.activeExplorer.goBack()
                }
                .disabled(!appState.activeExplorer.canGoBack)

                ToolbarBtn(icon: "chevron.right", tip: "Forward") {
                    appState.activeExplorer.goForward()
                }
                .disabled(!appState.activeExplorer.canGoForward)
            }
            .padding(3)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.leading, 12)

            Spacer()

            // Center group: file operations
            HStack(spacing: 2) {
                ToolbarBtn(icon: "doc.on.doc", tip: "Copy to Other Pane (F5)") {
                    appState.copyToOtherPane()
                }
                .disabled(!appState.showDualPane)

                ToolbarBtn(icon: "arrow.right.doc.on.clipboard", tip: "Move to Other Pane (F6)") {
                    appState.moveToOtherPane()
                }
                .disabled(!appState.showDualPane)

                ToolbarBtn(icon: "folder.badge.plus", tip: "New Folder") {
                    appState.activeExplorer.createNewFolder()
                }

                ToolbarBtn(icon: "trash", tip: "Delete") {
                    appState.activeExplorer.trashSelected()
                }

                ToolbarSep()

                ToolbarBtn(icon: "rectangle.split.2x1", isActive: appState.showDualPane, tip: "Dual Pane") {
                    withAnimation(.easeInOut(duration: 0.15)) { appState.showDualPane.toggle() }
                }

                ToolbarSep()

                ToolbarBtn(icon: "sidebar.right", isActive: appState.showInfoPanel, tip: "Info Panel") {
                    withAnimation(.easeInOut(duration: 0.15)) { appState.showInfoPanel.toggle() }
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Spacer()

            // Right group: search + actions
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                    TextField("Search", text: toolbarSearchBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .onChange(of: appState.activeExplorer.searchText) {
                            appState.activeExplorer.loadFiles()
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .frame(width: 170)

                Menu {
                    Toggle("Show Hidden Files", isOn: Binding(
                        get: { appState.activeExplorer.showHiddenFiles },
                        set: { appState.activeExplorer.showHiddenFiles = $0; appState.activeExplorer.loadFiles() }
                    ))
                    Divider()
                    Button("Open Terminal Here") {
                        let escapedPath = appState.activeExplorer.currentURL.path.replacingOccurrences(of: "'", with: "'\\''") 
                        let script = "tell application \"Terminal\" to do script \"cd '\(escapedPath)'\""
                        if let appleScript = NSAppleScript(source: script) {
                            var error: NSDictionary?
                            appleScript.executeAndReturnError(&error)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Toolbar Separator

struct ToolbarSep: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }
}

// MARK: - Toolbar Button

struct ToolbarBtn: View {
    let icon: String
    var isActive: Bool = false
    let tip: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? .accentColor : (hovering ? .primary : .secondary))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? Color.accentColor.opacity(0.15) : (hovering ? Color.primary.opacity(0.06) : Color.clear))
                )
        }
        .buttonStyle(.borderless)
        .help(tip)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovering)
    }
}
