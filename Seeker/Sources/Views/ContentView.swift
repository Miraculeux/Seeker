import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState

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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let window = NSApp.keyWindow ?? NSApp.windows.first {
                    window.makeFirstResponder(window.contentView)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.showGoToFolder },
            set: { appState.showGoToFolder = $0 }
        )) {
            GoToFolderSheet()
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.metadataEditorTargets != nil },
            set: { if !$0 { appState.metadataEditorTargets = nil } }
        )) {
            if let targets = appState.metadataEditorTargets {
                MetadataEditorSheet(targets: targets) {
                    appState.metadataEditorTargets = nil
                    appState.activeExplorer.loadFiles()
                }
                .environment(appState)
            }
        }
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

                ToolbarBtn(icon: "doc.badge.plus", tip: "New File") {
                    appState.activeExplorer.createNewFile()
                }

                ToolbarBtn(icon: "trash", tip: "Delete") {
                    appState.activeExplorer.trashSelected()
                }

                ToolbarBtn(icon: "terminal", tip: "Open Terminal") {
                    let escapedPath = appState.activeExplorer.currentURL.path.replacingOccurrences(of: "'", with: "'\\''")
                    let script = "tell application \"Terminal\" to do script \"cd '\(escapedPath)'\""
                    if let appleScript = NSAppleScript(source: script) {
                        var error: NSDictionary?
                        appleScript.executeAndReturnError(&error)
                    }
                }

                ToolbarBtn(
                    icon: "info.circle",
                    tip: "Edit Metadata (\u{2318}I)"
                ) {
                    appState.openMetadataEditor()
                }
                .disabled(!appState.activeExplorer.hasEditableImageSelection)
                .keyboardShortcut("i", modifiers: .command)

                ShareToolbarBtn(appState: appState)

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

            // Right group: progress indicator
            HStack(spacing: 6) {
                FileOperationCompactView()
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

// MARK: - Share Toolbar Button

struct ShareToolbarBtn: View {
    var appState: AppState
    @State private var hovering = false

    private var hasSelection: Bool {
        appState.activeExplorer.selectedFile != nil || !appState.activeExplorer.selectedFileIDs.isEmpty
    }

    var body: some View {
        Button {
            let urls = appState.activeExplorer.effectiveSelection.map(\.url)
            guard !urls.isEmpty else { return }
            let picker = NSSharingServicePicker(items: urls)
            if let window = NSApp.keyWindow, let contentView = window.contentView {
                let point = contentView.convert(NSEvent.mouseLocation, from: nil)
                picker.show(relativeTo: NSRect(origin: point, size: .zero), of: contentView, preferredEdge: .minY)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hasSelection ? (hovering ? .primary : .secondary) : .secondary.opacity(0.25))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering && hasSelection ? Color.primary.opacity(0.06) : Color.clear)
                )
        }
        .buttonStyle(.borderless)
        .disabled(!hasSelection)
        .onHover { hovering = $0 }
        .help("Share")
        .animation(.easeInOut(duration: 0.1), value: hovering)
    }
}

// MARK: - Go to Folder Sheet

private struct GoToFolderSheet: View {
    @Environment(AppState.self) var appState
    @State private var path: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Go to Folder")
                .font(.headline)

            Text("Enter a path to navigate to:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("/path/to/folder", text: $path)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .onSubmit { go() }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go") { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty)
            }
        }
        .padding(24)
        .onAppear {
            path = appState.activeExplorer.currentURL.path
        }
    }

    private func go() {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            appState.activeExplorer.navigateTo(url)
            dismiss()
        } else {
            NSSound.beep()
        }
    }
}
