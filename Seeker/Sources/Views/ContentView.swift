import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

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
                        .frame(width: theme.isExplorer ? 190 : 140)
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
        .sheet(isPresented: Binding(
            get: { appState.mediaMetadataEditorTargets != nil },
            set: { if !$0 { appState.mediaMetadataEditorTargets = nil } }
        )) {
            if let targets = appState.mediaMetadataEditorTargets {
                MediaMetadataEditorSheet(targets: targets) {
                    appState.mediaMetadataEditorTargets = nil
                    appState.activeExplorer.loadFiles()
                }
                .environment(appState)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.batchRenameTargets != nil },
            set: { if !$0 { appState.batchRenameTargets = nil } }
        )) {
            if let targets = appState.batchRenameTargets {
                BatchRenameView(urls: targets) { _ in
                    appState.activeExplorer.loadFiles()
                    NotificationCenter.default.post(name: .filesDidChange, object: nil)
                }
            }
        }
        .onChange(of: appState.duplicateFinderRoots) { _, newValue in
            // The duplicate finder lives in its own window so the main
            // window stays interactive while the user reviews matches.
            // Reset the trigger after dispatching so the same folders can
            // be re-opened later.
            if let urls = newValue, !urls.isEmpty {
                openWindow(id: "duplicate-finder", value: DuplicateFinderWindowRequest(
                    rootURLs: urls,
                    sourceWindowID: appState.windowID
                ))
                appState.duplicateFinderRoots = nil
            }
        }
        .onChange(of: appState.directoryCompareTargets) { _, newValue in
            // The compare window is standalone like the duplicate finder.
            if let dirs = newValue, dirs.count == 2 {
                openWindow(id: "directory-compare", value: DirectoryCompareWindowRequest(
                    directories: dirs,
                    sourceWindowID: appState.windowID
                ))
                appState.directoryCompareTargets = nil
            }
        }
        .onChange(of: appState.fileSearchRoot) { _, newValue in
            if let root = newValue {
                openWindow(id: "file-search", value: FileSearchWindowRequest(
                    root: root,
                    sourceWindowID: appState.windowID
                ))
                appState.fileSearchRoot = nil
            }
        }
        .onChange(of: appState.similarImageRequest) { _, newValue in
            if let request = newValue {
                openWindow(id: "similar-images", value: request)
                appState.similarImageRequest = nil
            }
        }
        .onChange(of: appState.semanticSearchRequest) { _, newValue in
            if let request = newValue {
                openWindow(id: "semantic-search", value: request)
                appState.semanticSearchRequest = nil
            }
        }
        .onChange(of: appState.folderSyncRoots) { _, newValue in
            if let dirs = newValue, dirs.count == 2 {
                openWindow(id: "folder-sync", value: FolderSyncWindowRequest(
                    directories: dirs,
                    sourceWindowID: appState.windowID
                ))
                appState.folderSyncRoots = nil
            }
        }
    }

// MARK: - Modern Toolbar

    @ViewBuilder
    private var mainToolbar: some View {
        if theme.isExplorer {
            explorerCommandBar
        } else {
            nativeMainToolbar
        }
    }

    private var explorerCommandBar: some View {
        let explorer = appState.activeExplorer
        let palette = ThemePalette(style: theme.interfaceStyle, colorScheme: colorScheme)
        return HStack(spacing: 4) {
            ExplorerCommandButton(icon: "folder.badge.plus", title: "New") {
                explorer.createNewFolder()
            }

            ToolbarSep()

            ExplorerCommandButton(icon: "scissors", title: "Cut", disabled: !explorer.hasSelection) {
                explorer.cutSelected()
            }
            ExplorerCommandButton(icon: "doc.on.doc", title: "Copy", disabled: !explorer.hasSelection) {
                explorer.copySelected()
            }
            ExplorerCommandButton(icon: "doc.on.clipboard", title: "Paste", disabled: !explorer.canPaste) {
                explorer.paste()
            }
            ExplorerCommandButton(icon: "character.cursor.ibeam", title: "Rename", disabled: explorer.selectedFile == nil) {
                if let file = explorer.selectedFile { explorer.beginRename(file) }
            }
            ExplorerCommandButton(icon: "square.and.arrow.up", title: "Share", disabled: !explorer.hasSelection) {
                let picker = NSSharingServicePicker(items: explorer.effectiveSelection.map(\.url))
                if let window = NSApp.keyWindow, let contentView = window.contentView {
                    picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
                }
            }
            ExplorerCommandButton(icon: "trash", title: "Delete", disabled: !explorer.hasSelection) {
                explorer.trashSelected()
            }

            ToolbarSep()

            Menu {
                Picker("Sort by", selection: Binding(
                    get: { explorer.sortOrder },
                    set: { explorer.sortOrder = $0; explorer.resort() }
                )) {
                    ForEach(FileExplorerViewModel.SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                Divider()
                Button(explorer.sortAscending ? "Descending" : "Ascending") {
                    explorer.sortAscending.toggle()
                    explorer.resort()
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("Details") { explorer.viewMode = .list }
                Button("Icons") { explorer.viewMode = .icons }
                Button("Columns") { explorer.viewMode = .columns }
                Divider()
                Button(explorer.showHiddenFiles ? "Hide hidden items" : "Show hidden items") {
                    explorer.showHiddenFiles.toggle()
                    explorer.loadFiles()
                }
                Button(appState.showInfoPanel ? "Hide details pane" : "Show details pane") {
                    withAnimation { appState.showInfoPanel.toggle() }
                }
            } label: {
                Label("View", systemImage: "rectangle.grid.1x2")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("New File") { explorer.createNewFile() }
                Button("Open Terminal Here") { SystemTerminal.open(at: explorer.currentURL) }
                Button("Edit Metadata") { appState.openMetadataEditor() }
                    .disabled(!explorer.hasEditableMetadataSelection)
                Button("Batch Rename") { appState.openBatchRename() }
                    .disabled(!explorer.hasSelection)
                Divider()
                Button("Copy to Other Pane") { appState.copyToOtherPane() }
                    .disabled(!appState.showDualPane || !explorer.hasSelection)
                Button("Move to Other Pane") { appState.moveToOtherPane() }
                    .disabled(!appState.showDualPane || !explorer.hasSelection)
                Button("Swap Panes") { appState.swapPanes() }
                    .disabled(!appState.showDualPane)
                Divider()
                Button("Search") { appState.openSearch() }
                Button("Find Duplicates") { appState.openDuplicateFinder() }
                Button("Compare Folders") { appState.openDirectoryCompare() }
                    .disabled(!appState.canCompareDirectories)
                Button("Semantic Image Search") { appState.openSemanticSearch() }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 8)

            FileOperationCompactView()
                .frame(width: 220, alignment: .trailing)

            ToolbarSep()

            ExplorerCommandButton(
                icon: appState.showDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                title: "Panes",
                isActive: appState.showDualPane
            ) {
                withAnimation(.easeInOut(duration: 0.15)) { appState.showDualPane.toggle() }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(palette.chromeBackground)
    }

    private var nativeMainToolbar: some View {
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

            // Center groups: file ops, pane transfer, analysis, view
            HStack(spacing: 8) {
                // Group 4: general file operations
                HStack(spacing: 2) {
                    ToolbarBtn(icon: "folder.badge.plus", tip: "New Folder") {
                        appState.activeExplorer.createNewFolder()
                    }

                    ToolbarBtn(icon: "doc.badge.plus", tip: "New File") {
                        appState.activeExplorer.createNewFile()
                    }

                    FavoriteToolbarBtn(appState: appState)

                    ToolbarBtn(icon: "terminal", tip: "Open Terminal") {
                        SystemTerminal.open(at: appState.activeExplorer.currentURL)
                    }

                    ToolbarBtn(
                        icon: "info.circle",
                        tip: "Edit Metadata (\u{2318}I)"
                    ) {
                        appState.openMetadataEditor()
                    }
                    .disabled(!appState.activeExplorer.hasEditableMetadataSelection)
                    .keyboardShortcut("i", modifiers: .command)

                    ToolbarBtn(
                        icon: "character.cursor.ibeam",
                        tip: "Batch Rename (\u{2318}\u{21E7}R)"
                    ) {
                        appState.openBatchRename()
                    }
                    .disabled(!appState.activeExplorer.hasSelection)

                    ShareToolbarBtn(appState: appState)

                    ToolbarBtn(icon: "trash", tip: "Delete") {
                        appState.activeExplorer.trashSelected()
                    }
                    .disabled(!appState.activeExplorer.hasSelection)
                }
                .padding(3)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                // Group 1: pane transfer
                HStack(spacing: 2) {
                    ToolbarBtn(icon: "doc.on.doc", tip: "Copy to Other Pane (F5)") {
                        appState.copyToOtherPane()
                    }
                    .disabled(!appState.showDualPane || !appState.activeExplorer.hasSelection)

                    ToolbarBtn(icon: "arrow.right.doc.on.clipboard", tip: "Move to Other Pane (F6)") {
                        appState.moveToOtherPane()
                    }
                    .disabled(!appState.showDualPane || !appState.activeExplorer.hasSelection)

                    ToolbarBtn(icon: "arrow.left.arrow.right", tip: "Swap Panes") {
                        appState.swapPanes()
                    }
                    .disabled(!appState.showDualPane)
                }
                .padding(3)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                // Group 2: duplicates + compare
                HStack(spacing: 2) {
                    ToolbarBtn(
                        icon: "magnifyingglass",
                        tip: "Search (\u{2318}F)"
                    ) {
                        appState.openSearch()
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    ToolbarBtn(
                        icon: "photo.stack",
                        tip: "Find Visually Similar Images"
                    ) {
                        appState.openSimilarImageSearch()
                    }
                    .disabled(!appState.activeExplorer.canOpenSimilarImageSearch)

                    ToolbarBtn(
                        icon: "brain",
                        tip: "Semantic Image Search"
                    ) {
                        appState.openSemanticSearch()
                    }

                    ToolbarBtn(
                        icon: "doc.on.doc",
                        tip: "Find Duplicates (\u{2318}\u{21E7}D)"
                    ) {
                        appState.openDuplicateFinder()
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                    ToolbarBtn(
                        icon: "doc.on.doc.fill",
                        tip: "Find Duplicates Across Panes (\u{2318}\u{2325}D)"
                    ) {
                        appState.openDuplicateFinderAcrossPanes()
                    }
                    .disabled(!appState.showDualPane)
                    .keyboardShortcut("d", modifiers: [.command, .option])

                    ToolbarBtn(
                        icon: "arrow.left.arrow.right.square",
                        tip: "Compare Folders (\u{2318}\u{21E7}K)"
                    ) {
                        appState.openDirectoryCompare()
                    }
                    .disabled(!appState.canCompareDirectories)
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                }
                .padding(3)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                // Group 3: view toggles
                HStack(spacing: 2) {
                    ToolbarBtn(icon: "rectangle.split.2x1", isActive: appState.showDualPane, tip: "Dual Pane") {
                        withAnimation(.easeInOut(duration: 0.15)) { appState.showDualPane.toggle() }
                    }

                    ToolbarBtn(icon: "sidebar.right", isActive: appState.showInfoPanel, tip: "Info Panel") {
                        withAnimation(.easeInOut(duration: 0.15)) { appState.showInfoPanel.toggle() }
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            Spacer()

            // Right group: progress indicator. Reserve a fixed-width slot so
            // the compact view's fluctuating text (speed / time / size) never
            // changes the toolbar's overall layout — otherwise the flanking
            // Spacers rebalance on every progress tick and the centered button
            // groups visibly shake.
            HStack(spacing: 6) {
                FileOperationCompactView()
            }
            .frame(width: 220, alignment: .trailing)
            .padding(.trailing, 12)
        }
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Explorer Command Button

private struct ExplorerCommandButton: View {
    let icon: String
    let title: String
    var isActive = false
    var disabled = false
    let action: () -> Void

    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let palette = ThemePalette(style: theme.interfaceStyle, colorScheme: colorScheme)
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : .primary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? palette.selection : (hovering && !disabled ? palette.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
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
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? Color.accentColor.opacity(0.15) : (hovering && isEnabled ? Color.primary.opacity(0.06) : Color.clear))
                )
        }
        .buttonStyle(.borderless)
        .help(tip)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovering)
    }

    private var iconColor: Color {
        if !isEnabled { return .secondary.opacity(0.25) }
        if isActive { return .accentColor }
        return hovering ? .primary : .secondary
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

// MARK: - Favorite Toolbar Button

/// Toggles whether the active pane's current folder is in the user
/// favorites list. The icon flips between an outlined and a filled star
/// to reflect membership, and updates live when favorites change from
/// elsewhere (e.g. the sidebar's add/remove menus).
struct FavoriteToolbarBtn: View {
    var appState: AppState
    @State private var isFavorite: Bool = false
    @State private var hovering = false

    var body: some View {
        Button {
            let url = appState.activeExplorer.currentURL
            if SettingsManager.shared.isUserFavorite(url) {
                SettingsManager.shared.removeFavorite(url)
            } else {
                SettingsManager.shared.addFavorite(url)
            }
            refreshState()
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isFavorite ? .yellow : (hovering ? .primary : .secondary))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
                )
        }
        .buttonStyle(.borderless)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovering)
        .animation(.easeInOut(duration: 0.1), value: isFavorite)
        .onAppear { refreshState() }
        .onChange(of: appState.activeExplorer.currentURL) { _, _ in refreshState() }
        .onReceive(NotificationCenter.default.publisher(for: .favoritesChanged)) { _ in
            refreshState()
        }
    }

    private func refreshState() {
        isFavorite = SettingsManager.shared.isUserFavorite(appState.activeExplorer.currentURL)
    }
}

