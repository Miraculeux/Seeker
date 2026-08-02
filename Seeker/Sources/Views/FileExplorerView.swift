import SwiftUI
import QuickLookUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import CommonCrypto

/// After focusing a rename `TextField`, select only the basename (excludes
/// the trailing extension) so typing immediately replaces the name without
/// clobbering the extension — matches Finder's rename behaviour. For names
/// with no extension or dotfiles like `.gitignore` this is a no-op, leaving
/// the default select-all in effect.
@MainActor
fileprivate func selectFilenameBasenameInFieldEditor(_ name: String) {
    guard let window = NSApp.keyWindow,
          let editor = window.firstResponder as? NSTextView,
          editor.isFieldEditor else { return }
    let ns = name as NSString
    let dot = ns.range(of: ".", options: .backwards)
    guard dot.location != NSNotFound, dot.location > 0 else { return }
    editor.selectedRange = NSRange(location: 0, length: dot.location)
}

// MARK: - File Content View (supports list, icon, column modes)

struct FileContentView: View {
    @Bindable var viewModel: FileExplorerViewModel
    @Environment(AppState.self) var appState
    let side: AppState.PaneSide
    @State private var quickLookURL: URL?
    @State private var showQuickLook = false
    @State private var columnRefresh: Int = 0
    /// Last file id auto-scrolled to in list mode; used to suppress
    /// redundant `scrollTo` calls when the focused selection hasn't moved.
    @State private var lastScrolledID: FileItem.ID?
    /// Icon size at the start of the current pinch gesture, used so the
    /// gesture's multiplicative magnification scales from a stable base.
    @State private var pinchBaseSize: CGFloat?

    var body: some View {
        Group {
            switch viewModel.viewMode {
            case .list:
                // Scope columnRefresh to the views that actually depend on
                // column settings; avoids nuking the entire view tree's
                // identity (List recycling, scroll position) on a settings
                // change that does not affect the column browser.
                listView.id(columnRefresh)
            case .icons:
                iconGridView
            case .columns:
                columnView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { viewModel.showError = false }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $showQuickLook) {
            if let url = quickLookURL {
                QuickLookPreview(url: url)
                    .frame(minWidth: 600, minHeight: 400)
            }
        }
        .onChange(of: viewModel.selectedFileIDs) { _, _ in
            if let file = viewModel.selectedFile {
                AppDelegate.shared?.updateQuickLookIfVisible(url: file.url)
                AppDelegate.shared?.updateTextPreviewIfVisible(url: file.url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .columnSettingsChanged)) { _ in
            columnRefresh += 1
        }
    }

    // MARK: - List View

    private var listView: some View {
        let visibleColumns = SettingsManager.shared.visibleColumnsOrdered
        let files = viewModel.files
        let altRowColor = Color(nsColor: NSColor.alternatingContentBackgroundColors.indices.contains(1)
            ? NSColor.alternatingContentBackgroundColors[1]
            : NSColor.controlBackgroundColor)
        return VStack(spacing: 0) {
            // Column header
            listHeader
            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(files) { file in
                        FileListRow(
                            file: file,
                            isSelected: isFileSelected(file),
                            isRenaming: viewModel.renamingFile == file,
                            depth: viewModel.depth(of: file),
                            isExpandable: viewModel.isExpandable(file),
                            isExpanded: viewModel.isExpanded(file),
                            isLoadingChildren: viewModel.isLoadingChildren(file),
                            visibleColumns: visibleColumns,
                            altBackground: altRowColor,
                            alternating: !(viewModel.fileRowIndex(file).isMultiple(of: 2)),
                            renameText: $viewModel.renameText,
                            onCommitRename: { viewModel.commitRename() },
                            onCancelRename: { viewModel.cancelRename() },
                            onToggleExpand: { viewModel.toggleExpanded(file) }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .overlay(RightClickCatcher { ensureContextSelection(file) })
                        // Native AppKit drag source. Handles click/select and
                        // drag initiation so the drag pasteboard advertises the
                        // legacy NSFilenamesPboardType/NSURL that classic apps
                        // (e.g. IINA) require — SwiftUI's `.onDrag` only exposes
                        // modern promised UTIs and never reaches them.
                        .overlay(dragCatcher(for: file, chevron: chevronRange(for: file)))
                        .contextMenu { fileContextMenu(for: file) }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 22)
                .contextMenu { directoryContextMenu }
                .onChange(of: viewModel.selectedFileIDs) { _, _ in
                    if let file = viewModel.selectedFile, file.id != lastScrolledID {
                        lastScrolledID = file.id
                        proxy.scrollTo(file.id)
                    }
                }
                .onDrop(of: [.fileURL, .image, .url], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                    return true
                }
            }
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .contextMenu { directoryContextMenu }
        }
    }

    private var listHeader: some View {
        // Read once per header redraw rather than on every iteration of the
        // ForEach below (and per row in `FileListRow`).
        let columns = SettingsManager.shared.visibleColumnsOrdered
        return HStack(spacing: 0) {
            sortableHeader("Name", sortKey: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { col in
                switch col {
                case .size:
                    sortableHeader("Size", sortKey: .size)
                        .frame(width: 80, alignment: .trailing)
                case .modified:
                    sortableHeader("Modified", sortKey: .date)
                        .frame(width: 140, alignment: .trailing)
                case .kind:
                    sortableHeader("Kind", sortKey: .kind)
                        .frame(width: 100, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundColor(.secondary.opacity(0.6))
    }

    private func sortableHeader(_ title: String, sortKey: FileExplorerViewModel.SortOrder) -> some View {
        Button {
            if viewModel.sortOrder == sortKey {
                viewModel.sortAscending.toggle()
            } else {
                viewModel.sortOrder = sortKey
                viewModel.sortAscending = true
            }
            viewModel.resort()
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if viewModel.sortOrder == sortKey {
                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func unfocusTextFields() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// URLs to carry when a drag starts on `file`: the whole selection when
    /// `file` is part of a multi-selection, otherwise just `file`.
    private func dragURLs(for file: FileItem) -> [URL] {
        if viewModel.selectedFileIDs.contains(file.id) && viewModel.selectedFileIDs.count > 1 {
            return viewModel.files
                .filter { viewModel.selectedFileIDs.contains($0.id) }
                .map(\.url)
        }
        return [file.url]
    }

    /// x-range (in row-local points) occupied by the disclosure chevron, so
    /// the drag catcher can forward clicks there to expand/collapse instead
    /// of selecting. `nil` for non-expandable rows. Mirrors the geometry in
    /// `FileListRow` (4pt row padding, 14pt indent/level, 22pt chevron).
    private func chevronRange(for file: FileItem) -> ClosedRange<CGFloat>? {
        guard viewModel.isExpandable(file) else { return nil }
        let minX: CGFloat = 4 + CGFloat(viewModel.depth(of: file)) * 14
        return minX...(minX + 22)
    }

    /// Native AppKit drag/click overlay for a row or icon cell. Handles
    /// selection, double-click open, chevron expand, and — crucially — starts
    /// a real AppKit dragging session whose pasteboard advertises legacy
    /// file types so classic apps like IINA accept the drop with the
    /// original path.
    private func dragCatcher(for file: FileItem, chevron: ClosedRange<CGFloat>? = nil) -> some View {
        FileDragCatcher(
            isEnabled: viewModel.renamingFile != file,
            chevronRange: chevron,
            urls: { dragURLs(for: file) },
            onClick: { command, shift, clickCount in
                if clickCount >= 2 {
                    viewModel.openItem(file)
                } else {
                    unfocusTextFields()
                    viewModel.handleFileClick(file, command: command, shift: shift)
                    appState.activePane = side
                }
            },
            onToggleExpand: chevron == nil ? nil : { viewModel.toggleExpanded(file) }
        )
    }

    private func updateIconGridColumnCount(width: CGFloat) {
        let itemMin: CGFloat = iconCellWidth
        let spacing: CGFloat = 8
        let padded = width - 24 // 12pt padding on each side
        let count = max(1, Int((padded + spacing) / (itemMin + spacing)))
        viewModel.iconGridColumnCount = count
    }

    /// Outer width of an icon-grid cell. Scales with the user-chosen icon
    /// size; the extra 28pt absorbs label padding and the rename text
    /// field so wide names don't reflow the grid.
    private var iconCellWidth: CGFloat {
        viewModel.iconSize + 42
    }

    private func isFileSelected(_ file: FileItem) -> Bool {
        if !viewModel.selectedFileIDs.isEmpty {
            return viewModel.selectedFileIDs.contains(file.id)
        }
        return viewModel.selectedFile == file
    }

    // MARK: - Icon Grid View

    private var iconGridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: iconCellWidth, maximum: iconCellWidth + 20), spacing: 8)],
                spacing: 8
            ) {
                ForEach(viewModel.files) { file in
                    FileIconCell(
                        file: file,
                        iconSize: viewModel.iconSize,
                        isLiveZooming: viewModel.isLiveZooming,
                        isSelected: isFileSelected(file),
                        isRenaming: viewModel.renamingFile == file,
                        renameText: $viewModel.renameText,
                        onCommitRename: { viewModel.commitRename() },
                        onCancelRename: { viewModel.cancelRename() }
                    )
                    .equatable()
                    .overlay(RightClickCatcher { ensureContextSelection(file) })
                    .overlay(dragCatcher(for: file))
                    .contextMenu { fileContextMenu(for: file) }
                }
            }
            .padding(12)
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        updateIconGridColumnCount(width: geo.size.width)
                    }
                    .onChange(of: geo.size.width) { _, newWidth in
                        updateIconGridColumnCount(width: newWidth)
                    }
                    // Recompute column count only when the icon size
                    // truly settles (gesture end / keyboard / menu),
                    // not on every pinch tick. The grid itself uses
                    // GridItem(.adaptive) so layout still tracks the
                    // live size; this just keeps `iconGridColumnCount`
                    // (used for arrow-key navigation) in sync without
                    // bouncing through @Observable on every micro-step.
                    .onChange(of: viewModel.iconSize) { oldValue, newValue in
                        // Throttle: only recompute when bucket-sized
                        // jumps occur. Sub-8pt drifts during pinch are
                        // ignored; the snap at gesture end will catch up.
                        if abs(newValue - oldValue) >= 8 {
                            updateIconGridColumnCount(width: geo.size.width)
                        }
                    }
                }
            )
        }
        .contextMenu { directoryContextMenu }
        .onDrop(of: [.fileURL, .image, .url], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        // Pinch-to-zoom on the icon grid. The gesture state's `magnification`
        // is multiplicative; we apply it to the icon size we had when the
        // gesture began so the size tracks the fingers smoothly. We use
        // `setIconSizeLive` so we don't churn UserDefaults / cross-pane
        // notifications on every tick — commit happens on `.onEnded`.
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    if pinchBaseSize == nil { pinchBaseSize = viewModel.iconSize }
                    let base = pinchBaseSize ?? viewModel.iconSize
                    let raw = base * value.magnification
                    // Quantise to 2pt so we don't trigger a fresh layout
                    // pass on every imperceptible movement.
                    let quantised = (raw / 2).rounded() * 2
                    if quantised != viewModel.iconSize {
                        viewModel.setIconSizeLive(quantised)
                    }
                }
                .onEnded { _ in
                    pinchBaseSize = nil
                    let steps = FileExplorerViewModel.iconZoomSteps
                    let current = viewModel.iconSize
                    let snapped = steps.min(by: { abs($0 - current) < abs($1 - current) }) ?? current
                    viewModel.commitIconSize(snapped)
                }
        )
        // Mouse-wheel zoom: hold ⌘ + scroll while pointer is over the grid.
        .onContinuousHover { _ in /* keep view active for scroll events */ }
    }

    // MARK: - Column View

    private var columnView: some View {
        ColumnBrowserView(viewModel: viewModel, side: side)
    }

    // MARK: - Context Menus

    /// Ensure the right-clicked file participates in the selection that
    /// the context-menu actions operate on. SwiftUI's `.contextMenu` on
    /// macOS does not auto-select the clicked row, so without this the
    /// menu items (Copy / Cut / Rename / Trash / …) would silently act
    /// on whatever was previously selected. If the clicked file is
    /// already part of a multi-selection we leave the selection alone
    /// so menu actions can apply to the whole group.
    ///
    /// Invoked from the AppKit right-click detector (`RightClickCatcher`)
    /// attached to each row, so it runs only on actual right-mouse-down
    /// events — never during ordinary view updates.
    fileprivate func ensureContextSelection(_ file: FileItem) {
        if viewModel.selectedFileIDs.contains(file.id) { return }
        if viewModel.selectedFileIDs.isEmpty, viewModel.selectedFile == file {
            appState.activePane = side
            return
        }
        viewModel.selectionAnchor = file
        viewModel.selectedFileIDs = [file.id]
        appState.activePane = side
    }

    /// Resolve the ordered list of file URLs to feed into an Auto Preview
    /// slideshow triggered from `file`'s context menu.
    /// - If 2+ items are currently selected, use those in the listing's
    ///   visible order (excluding non-package folders).
    /// - If a single folder is clicked, enumerate its direct children
    ///   using this pane's current sort order and hidden-file setting.
    /// - Otherwise returns an empty array (Auto Preview hidden from menu).
    fileprivate func autoPreviewURLs(forContext file: FileItem) -> [URL] {
        let selectedIDs = viewModel.selectedFileIDs
        if selectedIDs.count >= 2 {
            // Walk `viewModel.files` (already sorted in display order) and
            // keep selected, previewable entries. `effectiveSelection` is
            // backed by a Set and would yield an unstable iteration order.
            return viewModel.files.compactMap { item in
                guard selectedIDs.contains(item.id) else { return nil }
                guard !item.isDirectory || item.isPackage else { return nil }
                return item.url
            }
        }
        if file.isDirectory && !file.isPackage {
            let children = viewModel.sortedChildren(of: file.url)
            return children
                .filter { !$0.isDirectory || $0.isPackage }
                .map(\.url)
        }
        return []
    }

    /// Cheap predicate for whether the "Auto Preview" item should appear
    /// in `fileContextMenu`. Avoids the disk enumeration that
    /// `autoPreviewURLs` performs for folder right-clicks — the menu is
    /// rebuilt on every right-click, so the latter must not run from
    /// here. Folder branch optimistically returns `true`; the action
    /// closure re-checks before starting the slideshow.
    fileprivate func hasAutoPreviewCandidates(forContext file: FileItem) -> Bool {
        let selectedIDs = viewModel.selectedFileIDs
        if selectedIDs.count >= 2 {
            var matches = 0
            for item in viewModel.files {
                guard selectedIDs.contains(item.id) else { continue }
                guard !item.isDirectory || item.isPackage else { continue }
                matches += 1
                if matches >= 2 { return true }
            }
            return false
        }
        return file.isDirectory && !file.isPackage
    }

    /// Cheap predicate for the directory-background "Auto Preview" menu
    /// item. Early-exits as soon as two previewable entries are seen,
    /// avoiding the O(files) filter+map of the original implementation.
    fileprivate func directoryHasMultiplePreviewable() -> Bool {
        var matches = 0
        for item in viewModel.files where !item.isDirectory || item.isPackage {
            matches += 1
            if matches >= 2 { return true }
        }
        return false
    }

    /// Persists `appURL` as the always-open-with app for `ext` and opens
    /// `fileURL` with it immediately so the choice takes effect at once.
    private func setDefaultApp(_ appURL: URL, forExtension ext: String, openNow fileURL: URL) {
        SettingsManager.shared.setDefaultApp(appURL, forExtension: ext)
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @ViewBuilder
    private func fileContextMenu(for file: FileItem) -> some View {
        Button("Open") { viewModel.openItem(file) }
        if !file.isDirectory || file.isPackage {
            let appURLs = OpenWithAppsCache.apps(for: file.url)
            if !appURLs.isEmpty {
                Menu("Open With") {
                    ForEach(appURLs, id: \.self) { appURL in
                        Button(FileManager.default.displayName(atPath: appURL.path)) {
                            NSWorkspace.shared.open([file.url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    Divider()
                    Button("Other…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let appURL = panel.url {
                            NSWorkspace.shared.open([file.url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }

                // "Always Open With": persist a per-extension default app so
                // future opens (double-click / Enter / Open) use it. Only
                // meaningful for files that have an extension.
                let ext = file.url.pathExtension
                if !ext.isEmpty {
                    let currentDefault = SettingsManager.shared.defaultApp(forExtension: ext)
                    Menu("Always Open With") {
                        ForEach(appURLs, id: \.self) { appURL in
                            let isCurrent = currentDefault?.standardizedFileURL == appURL.standardizedFileURL
                            Button {
                                setDefaultApp(appURL, forExtension: ext, openNow: file.url)
                            } label: {
                                if isCurrent {
                                    Label(FileManager.default.displayName(atPath: appURL.path), systemImage: "checkmark")
                                } else {
                                    Text(FileManager.default.displayName(atPath: appURL.path))
                                }
                            }
                        }
                        Divider()
                        Button("Other…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.application]
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let appURL = panel.url {
                                setDefaultApp(appURL, forExtension: ext, openNow: file.url)
                            }
                        }
                        if currentDefault != nil {
                            Divider()
                            Button("Remove Default for .\(ext.lowercased())") {
                                SettingsManager.shared.setDefaultApp(nil, forExtension: ext)
                            }
                        }
                    }
                }
            }
        }

        if file.isPackage {
            Button("Show Package Contents") { viewModel.navigateTo(file.url) }
        }

        if !file.isDirectory {
            Button("Quick Look") {
                quickLookURL = file.url
                showQuickLook = true
            }
            Button("Quick Look As Text") {
                if let delegate = AppDelegate.shared {
                    if delegate.textPreviewPanel.isVisible {
                        delegate.textPreviewPanel.updatePreview(for: file.url)
                    } else {
                        delegate.textPreviewPanel.togglePreview(for: file.url)
                    }
                }
            }
        }

        // Cheap visibility check (no disk IO, early-exit on 2 matches).
        // Actual URL list — which may require a disk enumeration for
        // folder right-clicks — is collected only at click time.
        if hasAutoPreviewCandidates(forContext: file) {
            Button("Auto Preview") {
                let autoFiles = autoPreviewURLs(forContext: file)
                guard autoFiles.count >= 2 else { return }
                AppDelegate.shared?.quickLookPanel.startAutoPreview(
                    urls: autoFiles,
                    interval: SettingsManager.shared.autoPreviewInterval
                )
            }
        }

        Divider()

        Button("Copy") { viewModel.copySelected() }
        Button("Cut") { viewModel.cutSelected() }
        Button("Paste") { viewModel.paste() }

        Divider()

        if appState.showDualPane {
            Button("Copy to Other Pane") { appState.copyToOtherPane() }
            Button("Move to Other Pane") { appState.moveToOtherPane() }
            Divider()
        }

        Button(viewModel.effectiveSelection.count > 1 ? "Batch Rename…" : "Rename…") {
            if viewModel.effectiveSelection.count > 1 {
                appState.openBatchRename()
            } else {
                viewModel.beginRename(file)
            }
        }
        Button("Move to Trash") { viewModel.trashSelected() }
        Button("Delete Immediately…") { viewModel.deleteSelectedPermanently() }

        Divider()

        Button("Compress") { viewModel.compressSelected() }
        if viewModel.canDecompress(file) {
            Button("Decompress") { viewModel.decompressFile(file) }
        }

        if viewModel.effectiveSelection.contains(where: \.isNCMFile) {
            let ncmFiles = viewModel.effectiveSelection.filter(\.isNCMFile)
            Divider()
            Button("Dump Music (\(ncmFiles.count))") { viewModel.dumpNCMFiles(ncmFiles) }
        }

        if viewModel.effectiveSelection.contains(where: \.isEditableMetadata) {
            Divider()
            Menu("Metadata") {
                Button("Edit\u{2026}") { appState.openMetadataEditor() }
                    .keyboardShortcut("i", modifiers: .command)
                if viewModel.effectiveSelection.contains(where: \.isEditableImage) {
                    Divider()
                    Button("Strip GPS & Personal Info\u{2026}") {
                        appState.stripPrivacyMetadata()
                    }
                }
            }
        }

        Divider()

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.url.path, forType: .string)
        }

        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        }

        Button("Share…") {
            let urls = viewModel.effectiveSelection.map(\.url)
            guard !urls.isEmpty else { return }
            let picker = NSSharingServicePicker(items: urls)
            if let window = NSApp.keyWindow, let contentView = window.contentView {
                let point = contentView.convert(NSEvent.mouseLocation, from: nil)
                picker.show(relativeTo: NSRect(origin: point, size: .zero), of: contentView, preferredEdge: .minY)
            }
        }

        if file.isDirectory && file.containsNCMFiles {
            Divider()
            Button("Dump Music") { viewModel.dumpNCMFilesInFolder(file) }
        }

        if file.isDirectory {
            Divider()
            Button("Open in New Tab") {
                let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
                pane.addTab(url: file.url)
            }
            if appState.showDualPane {
                Button("Open in Other Pane") {
                    appState.inactivePaneState.activeTab.navigateTo(file.url)
                }
            }
            Divider()
            if SettingsManager.shared.isUserFavorite(file.url) {
                Button("Remove from Favorites") {
                    SettingsManager.shared.removeFavorite(file.url)
                }
            } else {
                Button("Add to Favorites") {
                    SettingsManager.shared.addFavorite(file.url)
                }
            }
        }
    }

    @ViewBuilder
    private var directoryContextMenu: some View {
        Button("New Folder") { viewModel.createNewFolder() }
        Button("New File") { viewModel.createNewFile() }
        Divider()
        Button("Paste") { viewModel.paste() }
        Divider()
        Button("Refresh") { viewModel.loadFiles() }
        Button("Open in Finder") {
            NSWorkspace.shared.open(viewModel.currentURL)
        }
        Button("Open Terminal Here") {
            openTerminal(at: viewModel.currentURL)
        }
        // Cheap check (early-exits at 2 matches). URL list is materialised
        // only when the user actually picks the menu item.
        if directoryHasMultiplePreviewable() {
            Divider()
            Button("Auto Preview") {
                let folderAutoFiles = viewModel.files
                    .filter { !$0.isDirectory || $0.isPackage }
                    .map(\.url)
                AppDelegate.shared?.quickLookPanel.startAutoPreview(
                    urls: folderAutoFiles,
                    interval: SettingsManager.shared.autoPreviewInterval
                )
            }
        }
        Divider()
        if SettingsManager.shared.isUserFavorite(viewModel.currentURL) {
            Button("Remove from Favorites") {
                SettingsManager.shared.removeFavorite(viewModel.currentURL)
            }
        } else {
            Button("Add to Favorites") {
                SettingsManager.shared.addFavorite(viewModel.currentURL)
            }
        }
        Divider()
        Toggle("Show Hidden Files", isOn: Binding(
            get: { viewModel.showHiddenFiles },
            set: { viewModel.showHiddenFiles = $0; viewModel.loadFiles() }
        ))
    }

    // MARK: - Drag and Drop

    private func handleDrop(providers: [NSItemProvider]) {
        let destDir = viewModel.currentURL
        let vm = viewModel
        let otherVM = (side == .left ? appState.rightPane : appState.leftPane).activeTab
        let isMove = NSEvent.modifierFlags.contains(.shift)

        // Split: local-file providers go through the move/copy pipeline,
        // everything else (browser image data, web URLs) goes through the
        // network/save importer.
        var fileProviders: [NSItemProvider] = []
        var remoteProviders: [NSItemProvider] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                fileProviders.append(provider)
            } else {
                remoteProviders.append(provider)
            }
        }

        if !fileProviders.isEmpty {
            // Collect all URLs first, then perform as a single operation
            final class URLCollector: @unchecked Sendable {
                private let lock = NSLock()
                private var urls = [URL]()
                func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
                var result: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
            }
            let collector = URLCollector()
            let group = DispatchGroup()

            for provider in fileProviders {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                    defer { group.leave() }
                    guard let data,
                          let sourceURL = URL(dataRepresentation: data, relativeTo: nil),
                          sourceURL.isFileURL else { return }
                    collector.append(sourceURL)
                }
            }

            group.notify(queue: .main) {
                let sourceURLs = collector.result
                guard !sourceURLs.isEmpty else { return }
                if isMove {
                    FileOperationManager.shared.startMove(sources: sourceURLs, to: destDir) { _ in
                        vm.loadFiles()
                        otherVM.loadFiles()
                    }
                } else {
                    FileOperationManager.shared.startCopy(sources: sourceURLs, to: destDir) { _ in
                        vm.loadFiles()
                        otherVM.loadFiles()
                    }
                }
            }
        }

        if !remoteProviders.isEmpty {
            BrowserDropImporter.importProviders(remoteProviders, into: destDir) {
                vm.loadFiles()
                otherVM.loadFiles()
            }
        }
    }

    private func openTerminal(at url: URL) {
        SystemTerminal.open(at: url)
    }
}

// MARK: - Terminal launcher

/// Opens Terminal.app with the given folder as its working directory while
/// guaranteeing that only one window is created.
///
/// Why this isn't a one-liner:
/// - `NSAppleScript("tell Terminal to do script \"cd …\"")` always *creates*
///   a new Terminal window. If Terminal wasn't already running, macOS also
///   opens a default `$HOME` window on launch — so the user ends up with
///   two windows, only one of which is at the requested path.
/// - `NSWorkspace.open([url], withApplicationAt: terminalURL)` has the same
///   double-window glitch when Terminal is cold-starting.
///
/// Strategy: if Terminal is already running, fall back to the simple
/// `do script` flow (one new window with `cd`). If Terminal is not running,
/// activate it and then `cd` *inside* the front window that the launch
/// produced, so we never get a stray `$HOME` window.
enum SystemTerminal {
    static func open(at url: URL) {
        let path = url.path
        // Reject characters that could break out of the AppleScript string
        // literal (quotes, backslash, newlines, separators, control chars).
        let forbidden: Set<Character> = ["\"", "\\", "\r", "\n", "\u{2028}", "\u{2029}", "\0"]
        let unsafe = path.contains {
            forbidden.contains($0) || ($0.asciiValue.map { $0 < 0x20 } ?? false)
        }
        if unsafe {
            // Fall back to NSWorkspace — it doesn't interpret the path as
            // code so it's injection-safe even though it may still produce
            // a default window on cold start.
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open(
                [url], withApplicationAt: terminalURL,
                configuration: cfg, completionHandler: nil
            )
            return
        }
        let shellEscaped = path.replacingOccurrences(of: "'", with: "'\\''")
        // The shell escaping above emits backslashes, which are also escape
        // characters in the AppleScript string literal these get embedded in;
        // without this the script fails to compile for any path containing an
        // apostrophe and nothing opens at all.
        let scriptEscaped = shellEscaped.replacingOccurrences(of: "\\", with: "\\\\")
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Terminal"
        }
        let script: String
        if isRunning {
            // Terminal is already up — open one new window with the cd
            // executed inline. Don't reuse an existing tab: the user may
            // have running work there.
            script = """
            tell application "Terminal"
                activate
                do script "cd '\(scriptEscaped)'"
            end tell
            """
        } else {
            // Cold start: activating Terminal opens one default ($HOME)
            // window. Wait for it, then run `cd` *inside* its selected tab.
            // This avoids spawning a second window and avoids the previous
            // approach of trying to close auto-opened defaults (Terminal's
            // `close … saving no` was a no-op against running-shell windows
            // in the user's environment, leaving the $HOME window visible).
            script = """
            tell application "Terminal"
                activate
                set tries to 0
                repeat while (count of windows) is 0 and tries < 40
                    delay 0.05
                    set tries to tries + 1
                end repeat
                do script "cd '\(scriptEscaped)'" in selected tab of front window
            end tell
            """
        }
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

// MARK: - List Row

struct FileListRow: View, @MainActor Equatable {
    let file: FileItem
    let isSelected: Bool
    let isRenaming: Bool
    let depth: Int
    let isExpandable: Bool
    let isExpanded: Bool
    let isLoadingChildren: Bool
    let visibleColumns: [ColumnID]
    let altBackground: Color
    let alternating: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onToggleExpand: () -> Void
    @State private var hovering = false
    @FocusState private var isRenameFocused: Bool

    /// Fixed row height. Enforced inside `body` so every row in the
    /// `LazyVStack` is exactly the same vertical size regardless of
    /// whether it shows a disclosure chevron, a progress spinner, or
    /// nothing — `LazyVStack` would otherwise let intrinsic content
    /// height vary by a point or two, producing visible jitter.
    private static let rowHeight: CGFloat = 22
    /// Pixels of indent per tree depth level. Matches Finder's list view.
    private static let indentPerLevel: CGFloat = 14
    /// Width reserved for the disclosure chevron column so name columns
    /// stay aligned whether or not the row is expandable. Wide enough
    /// that the chevron is comfortably clickable on a trackpad.
    private static let disclosureWidth: CGFloat = 22

    static func == (lhs: FileListRow, rhs: FileListRow) -> Bool {
        // Closures + binding compare by reference identity, which isn't
        // useful here; the inputs that actually drive the row's appearance
        // are file/selection/rename/columns/tree state. renameText is
        // intentionally excluded — when the row is in rename mode the
        // TextField owns editing state via @Binding and the parent
        // updates separately.
        lhs.file == rhs.file
            && lhs.isSelected == rhs.isSelected
            && lhs.isRenaming == rhs.isRenaming
            && lhs.depth == rhs.depth
            && lhs.isExpandable == rhs.isExpandable
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isLoadingChildren == rhs.isLoadingChildren
            && lhs.visibleColumns == rhs.visibleColumns
            && lhs.alternating == rhs.alternating
    }

    var body: some View {
        HStack(spacing: 0) {
            // Name column
            HStack(spacing: 7) {
                // Tree indent + disclosure chevron. Always reserve the
                // chevron's footprint so directories/files at the same
                // depth align on a common name baseline.
                if depth > 0 {
                    Color.clear
                        .frame(width: CGFloat(depth) * Self.indentPerLevel, height: 1)
                }
                disclosure
                Image(nsImage: file.nsIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)

                if isRenaming {
                    TextField("Name", text: $renameText, onCommit: onCommitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($isRenameFocused)
                        .onExitCommand(perform: onCancelRename)
                        .onAppear {
                            // Defer to the next runloop so the TextField
                            // is in the responder chain before we focus.
                            // Without this, focus assignment is dropped
                            // when the row appears as part of the same
                            // update that flipped `isRenaming` to true
                            // (e.g. right after creating a new folder).
                            DispatchQueue.main.async {
                                isRenameFocused = true
                                DispatchQueue.main.async {
                                    selectFilenameBasenameInFieldEditor(file.name)
                                }
                            }
                        }
                } else {
                    Text(file.displayName)
                        .font(.system(size: 12, weight: hovering ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Size
            // Date
            // Kind
            ForEach(visibleColumns) { col in
                switch col {
                case .size:
                    Text(file.formattedSize)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.7))
                        .frame(width: 80, alignment: .trailing)
                case .modified:
                    Text(file.formattedDate)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.7))
                        .frame(width: 140, alignment: .trailing)
                case .kind:
                    Text(file.typeDescription)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.7))
                        .frame(width: 100, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        ZStack {
            if alternating {
                altBackground
            }
            if hovering && !isSelected {
                Color.primary.opacity(0.03)
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.2))
                    .padding(.horizontal, 2)
            }
        }
    }

    /// Disclosure chevron / activity indicator shown at the start of
    /// each row. Always occupies the same width so name baselines line
    /// up regardless of whether the row is expandable.
    @ViewBuilder
    private var disclosure: some View {
        if isLoadingChildren {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: Self.disclosureWidth, height: Self.rowHeight)
        } else if isExpandable {
            Button(action: onToggleExpand) {
                // Outer frame defines the hit target; the glyph stays
                // small and centred. `contentShape` makes the entire
                // frame (including transparent margins) clickable.
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.75))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.12), value: isExpanded)
                    .frame(width: Self.disclosureWidth, height: Self.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The disclosure click must not propagate to the row's
            // tap-to-select gesture; otherwise expanding a folder
            // also selects it which feels jumpy.
            .simultaneousGesture(TapGesture().onEnded {})
        } else {
            Color.clear.frame(width: Self.disclosureWidth, height: Self.rowHeight)
        }
    }
}

// MARK: - Icon Grid Cell
// OpenWithAppsCache / ThumbnailCache / DiskThumbnailCache moved to ThumbnailCache.swift

struct FileIconCell: View, Equatable {
    let file: FileItem
    let iconSize: CGFloat
    let isLiveZooming: Bool
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @FocusState private var isRenameFocused: Bool

    /// SwiftUI uses this to short-circuit redraws when the visible inputs
    /// haven't changed. Two cells are equivalent iff every parameter that
    /// affects rendering matches; closures, `@State`, and `@Binding`
    /// channels are intentionally excluded — their identity churns on
    /// every parent body call but doesn't affect what we draw, and the
    /// rename `TextField` owns its own text via the binding so we don't
    /// need to compare it here.
    nonisolated static func == (lhs: FileIconCell, rhs: FileIconCell) -> Bool {
        lhs.file == rhs.file
            && lhs.iconSize == rhs.iconSize
            && lhs.isLiveZooming == rhs.isLiveZooming
            && lhs.isSelected == rhs.isSelected
            && lhs.isRenaming == rhs.isRenaming
    }

    /// Label font size scales with the icon — small icons get an 10pt
    /// label, large icons up to 13pt — so the cell stays balanced.
    private var labelFont: CGFloat {
        // Map iconSize 32...128 -> font 10...13
        let t = (iconSize - 32) / (128 - 32)
        return 10 + max(0, min(1, t)) * 3
    }

    /// Cell width must accommodate the icon plus a little label padding.
    private var cellWidth: CGFloat { iconSize + 42 }

    /// Cell height grows with the icon and leaves two label lines.
    private var cellHeight: CGFloat { iconSize + 42 }

    /// Quantises the requested icon size to a discrete bucket so small
    /// pinch movements don't trigger a flood of new QL renders.
    private var sizeBucket: Int {
        // Round up to the next zoom step so we never display an
        // upscaled (blurry) thumbnail.
        let steps = FileExplorerViewModel.iconZoomSteps
        for s in steps where CGFloat(Int(s)) >= iconSize { return Int(s) }
        return Int(steps.last ?? 128)
    }

    /// True when the thumbnail should occupy the full icon slot (no
    /// shadow/scale tricks that look weird on photos).
    private var hasThumbnail: Bool { thumbnail != nil }

    var body: some View {
        VStack(spacing: 6) {
            iconArtwork
                .frame(width: iconSize, height: iconSize)
                .shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 4 : 1, y: hovering ? 2 : 1)
                .scaleEffect(hovering ? 1.04 : 1.0)

            if isRenaming {
                TextField("", text: $renameText, onCommit: onCommitRename)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: labelFont))
                    .multilineTextAlignment(.center)
                    .focused($isRenameFocused)
                    .onExitCommand(perform: onCancelRename)
                    .onAppear {
                        DispatchQueue.main.async {
                            isRenameFocused = true
                            DispatchQueue.main.async {
                                selectFilenameBasenameInFieldEditor(file.name)
                            }
                        }
                    }
            } else {
                Text(file.displayName)
                    .font(.system(size: labelFont, weight: isSelected ? .medium : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
        }
        .frame(width: cellWidth, height: cellHeight)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (hovering ? Color.primary.opacity(0.04) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        // NOTE: deliberately no implicit animation on iconSize. During a
        // pinch each micro-step would otherwise spawn a fresh tween,
        // and SwiftUI ends up running dozens of overlapping animations
        // per frame across every visible cell. The size jumps directly
        // — the gesture itself provides the visual continuity.
        // Drives async thumbnail loading. Re-runs whenever the file id or
        // the size bucket changes; SwiftUI cancels the previous task
        // automatically so we never block the main actor.
        .task(id: thumbnailTaskID) { await loadThumbnailIfNeeded() }
    }

    /// Identity used by `.task(id:)` so re-renders for the same file at
    /// the same zoom bucket don't restart the thumbnail load. While a
    /// pinch gesture is active we collapse the bucket portion of the id
    /// so the task is *not* restarted on every intermediate bucket the
    /// gesture passes through — we just keep showing the cached
    /// fallback. The id flips back to the real bucket on commit, which
    /// fires one final exact-bucket render at the resting size.
    private var thumbnailTaskID: String {
        if isLiveZooming {
            return "\(file.id)\u{1}live"
        }
        return "\(file.id)\u{1}\(sizeBucket)"
    }

    @ViewBuilder
    private var iconArtwork: some View {
        if let thumb = thumbnail {
            // Photo-style framing: white card + thin border, mimicking
            // Finder's icon-view image preview.
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: iconSize, maxHeight: iconSize)
                .background(Color.white)
                .overlay(
                    Rectangle()
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                )
        } else {
            Image(nsImage: file.nsIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private func loadThumbnailIfNeeded() async {
        // Skip directories, packages, and anything we know QL won't
        // produce a useful preview for.
        guard !file.isDirectory, !file.isPackage,
              ThumbnailCache.canThumbnail(file.url) else {
            if thumbnail != nil { thumbnail = nil }
            return
        }

        // Fast path: if we have *any* cached render for this file, show
        // it immediately so the cell never blanks during a zoom. We
        // still kick off the exact-bucket render below so the result
        // sharpens to the right resolution as soon as it's ready.
        if let any = ThumbnailCache.cachedAny(for: file.url, preferredBucket: sizeBucket) {
            if thumbnail !== any { thumbnail = any }
            // If that hit was the exact bucket, no further work needed.
            if ThumbnailCache.cached(for: file.url, sizeBucket: sizeBucket) != nil {
                return
            }
        }

        // During an active zoom gesture, don't fire QL/disk reads at
        // every bucket the gesture passes through — the cached
        // fallback above is good enough. The commit at gesture end
        // flips the task id and re-runs us at the resting bucket.
        if isLiveZooming { return }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let url = file.url
        let bucket = sizeBucket
        let image = await ThumbnailCache.thumbnail(for: url, sizeBucket: bucket, scale: scale)
        guard !Task.isCancelled else { return }
        // Only swap if QL actually returned something better; otherwise
        // keep the fallback we already showed.
        if let image { thumbnail = image }
    }
}

// MARK: - Right-click Selection Helper

/// Transparent AppKit overlay that fires `onRightClick` when the user
/// right-clicks (or control + left-clicks) the file row it backs.
///
/// SwiftUI's `.contextMenu` on macOS displays the menu but does **not**
/// update selection on right-click, so menu actions like Copy / Trash
/// were operating on whatever was previously selected. We can't put the
/// "ensure selection" logic inside the `.contextMenu { ... }` builder
/// because SwiftUI evaluates that builder during ordinary view updates
/// (causing selection to bounce around at startup). Instead this view
/// observes the actual right-mouse event via AppKit and forwards it.
///
/// The custom `hitTest(_:)` returns the underlying view only for
/// right-mouse / control-click events so all other input (taps,
/// drags, scrolls) passes straight through to SwiftUI unchanged.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = RightClickNSView()
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RightClickNSView)?.onRightClick = onRightClick
    }
}

private final class RightClickNSView: NSView {
    var onRightClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept events that will trigger a context menu so we
        // don't disturb left-click / drag / scroll handling above us.
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return super.hitTest(point) == nil ? nil : self
        case .leftMouseDown, .leftMouseUp:
            // Ctrl-click on macOS is treated as a secondary click.
            if event.modifierFlags.contains(.control) {
                return super.hitTest(point) == nil ? nil : self
            }
            return nil
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
        // Forward up the responder chain so SwiftUI's `.contextMenu`
        // (attached to the row above us) still shows.
        super.rightMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Reached only when modifier-based hitTest above admitted us
        // (control + left-click). Treat as a secondary click.
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Native file drag source

/// AppKit-backed overlay that owns left-click selection and drag initiation
/// for a file row / icon cell.
///
/// Why not SwiftUI's `.onDrag`: on macOS `.onDrag` bridges an
/// `NSItemProvider` to the drag pasteboard advertising only modern, *promised*
/// UTIs (`public.file-url`). Classic AppKit apps such as IINA register for the
/// legacy `NSFilenamesPboardType` / `NSURL` drag types and never see the
/// promise, so the drop is silently rejected. Starting a real
/// `beginDraggingSession` with `NSURL` pasteboard writers eagerly publishes
/// those legacy types (pointing at the ORIGINAL path — no cache copy), so
/// every drop target works.
struct FileDragCatcher: NSViewRepresentable {
    var isEnabled: Bool = true
    var chevronRange: ClosedRange<CGFloat>? = nil
    let urls: () -> [URL]
    let onClick: (_ command: Bool, _ shift: Bool, _ clickCount: Int) -> Void
    var onToggleExpand: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = FileDragNSView()
        configure(v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? FileDragNSView else { return }
        configure(v)
    }

    private func configure(_ v: FileDragNSView) {
        v.isDragEnabled = isEnabled
        v.chevronRange = chevronRange
        v.urlsProvider = urls
        v.clickHandler = onClick
        v.toggleExpandHandler = onToggleExpand
    }
}

private final class FileDragNSView: NSView, NSDraggingSource {
    var isDragEnabled = true
    var chevronRange: ClosedRange<CGFloat>?
    var urlsProvider: (() -> [URL])?
    var clickHandler: ((Bool, Bool, Int) -> Void)?
    var toggleExpandHandler: (() -> Void)?

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // `.copy` outside the app (Finder/IINA/etc.), generic within.
        context == .withinApplication ? .generic : [.copy, .link, .generic]
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isDragEnabled else { return nil }
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            // Leave control-click to the right-click catcher below us.
            if event.modifierFlags.contains(.control) { return nil }
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        let threshold: CGFloat = 4
        var didDrag = false
        trackingLoop: while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            switch next.type {
            case .leftMouseDragged:
                if hypot(next.locationInWindow.x - start.x,
                         next.locationInWindow.y - start.y) > threshold {
                    didDrag = true
                    beginDrag(with: next)
                    break trackingLoop
                }
            case .leftMouseUp:
                break trackingLoop
            default:
                break
            }
        }
        guard !didDrag else { return }
        // A click (not a drag). Forward to the chevron toggle when it lands on
        // the disclosure triangle, otherwise to selection / open.
        if let range = chevronRange, let toggle = toggleExpandHandler {
            let local = convert(event.locationInWindow, from: nil)
            if range.contains(local.x) {
                toggle()
                return
            }
        }
        clickHandler?(event.modifierFlags.contains(.command),
                      event.modifierFlags.contains(.shift),
                      event.clickCount)
    }

    private func beginDrag(with event: NSEvent) {
        guard let urls = urlsProvider?(), !urls.isEmpty else { return }
        let origin = convert(event.locationInWindow, from: nil)
        let iconSize = NSSize(width: 32, height: 32)
        let items: [NSDraggingItem] = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = iconSize
            let offset = CGFloat(index) * 6
            item.setDraggingFrame(
                NSRect(x: origin.x - 16 + offset,
                       y: origin.y - 16 - offset,
                       width: iconSize.width, height: iconSize.height),
                contents: icon
            )
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
}

// MARK: - Column Browser View

struct ColumnBrowserView: View {
    @Bindable var viewModel: FileExplorerViewModel
    let side: AppState.PaneSide
    @State private var columnPath: [URL] = []
    @State private var columnSelections: [URL: FileItem] = [:]
    /// Last-known selection across all columns, kept so the file preview
    /// column can be rendered without recomputing `columnSelections[...]`
    /// from `body` each time.
    @State private var previewFile: FileItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                ForEach(Array(effectiveColumns.enumerated()), id: \.offset) { index, url in
                    VStack(spacing: 0) {
                        ColumnFileList(
                            directoryURL: url,
                            columnIndex: index,
                            showHiddenFiles: viewModel.showHiddenFiles,
                            selection: columnSelections[url],
                            onSelect: { handleSelection($0, at: url, columnIndex: index) },
                            onOpen: { viewModel.openItem($0) }
                        )
                    }
                    .frame(width: 220)

                    if index < effectiveColumns.count - 1 {
                        Divider()
                    }
                }

                // Preview column for selected file
                if let lastSel = previewFile, !lastSel.isDirectory {
                    Divider()
                    filePreviewColumn(lastSel)
                        .frame(width: 220)
                }
            }
        }
        .onAppear { rebuildColumns() }
        .onChange(of: viewModel.currentURL) { rebuildColumns() }
    }

    private var effectiveColumns: [URL] {
        [viewModel.currentURL] + columnPath
    }

    private func rebuildColumns() {
        columnPath = []
        columnSelections = [:]
        previewFile = nil
    }

    private func handleSelection(_ item: FileItem?, at directoryURL: URL, columnIndex: Int) {
        columnSelections[directoryURL] = item
        // Trim columns after this one
        if columnIndex == 0 {
            columnPath = []
        } else {
            columnPath = Array(columnPath.prefix(columnIndex))
        }
        // If directory, add as next column
        if let item, item.isDirectory {
            columnPath.append(item.url)
            previewFile = nil
        } else {
            previewFile = item
        }
        viewModel.selectionAnchor = item
        viewModel.selectedFileIDs = item.map { Set([$0.id]) } ?? []
    }

    private func filePreviewColumn(_ file: FileItem) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: file.nsIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            Text(file.displayName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            VStack(spacing: 3) {
                Text(file.formattedSize)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.7))
                Text(file.formattedDate)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Spacer()
        }
        .padding()
        .background(Color.primary.opacity(0.02))
    }
}

/// Single column in the column browser. Owns its loaded items as `@State`
/// and loads them off the main thread on appear / when inputs change.
/// Previously the parent's `body` ran a synchronous `contentsOfDirectory`
/// + per-file `lstat` per redraw on the cold-cache path, which stalled
/// the UI on directories with many entries.
private struct ColumnFileList: View {
    let directoryURL: URL
    let columnIndex: Int
    let showHiddenFiles: Bool
    let selection: FileItem?
    let onSelect: (FileItem?) -> Void
    let onOpen: (FileItem) -> Void

    @State private var items: [FileItem] = []
    @State private var loaded = false

    var body: some View {
        let binding = Binding<FileItem?>(get: { selection }, set: { onSelect($0) })
        return List(selection: binding) {
            ForEach(items) { file in
                HStack(spacing: 4) {
                    Image(nsImage: file.nsIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                    Text(file.displayName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    if file.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .tag(file)
                .onTapGesture {
                    if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                        onOpen(file)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !loaded && items.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: cacheKey) {
            // Warm-cache path resolves synchronously in the same tick;
            // cold path hops to a detached Task so directory enumeration
            // never blocks the main actor.
            if let cached = ColumnBrowserCache.shared.cached(forKey: cacheKey) {
                items = cached
                loaded = true
                return
            }
            let url = directoryURL
            let hidden = showHiddenFiles
            let loadedItems = await Task.detached(priority: .userInitiated) {
                ColumnBrowserCache.enumerate(at: url, showHidden: hidden)
            }.value
            if Task.isCancelled { return }
            ColumnBrowserCache.shared.store(loadedItems, forKey: cacheKey)
            items = loadedItems
            loaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .filesDidChange)) { _ in
            // Cache is wiped wholesale by ColumnBrowserCache's listener;
            // re-trigger our own load so the visible column reflects the
            // change without waiting for a navigation.
            loaded = false
            Task {
                let url = directoryURL
                let hidden = showHiddenFiles
                let key = cacheKey
                let fresh = await Task.detached(priority: .userInitiated) {
                    ColumnBrowserCache.enumerate(at: url, showHidden: hidden)
                }.value
                ColumnBrowserCache.shared.store(fresh, forKey: key)
                items = fresh
                loaded = true
            }
        }
    }

    private var cacheKey: NSString {
        "\(directoryURL.standardizedFileURL.path)|\(showHiddenFiles ? 1 : 0)" as NSString
    }
}

/// Process-wide cache for column-browser directory listings. Bounded so it
/// can't grow without limit while users navigate. Invalidated wholesale on
/// `.filesDidChange` so file ops in either pane are reflected.
@MainActor
final class ColumnBrowserCache {
    static let shared = ColumnBrowserCache()
    final class Entry { let items: [FileItem]; init(items: [FileItem]) { self.items = items } }
    let cache: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.countLimit = 64
        return c
    }()
    private init() {
        NotificationCenter.default.addObserver(
            forName: .filesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cache.removeAllObjects() }
        }
    }

    func cached(forKey key: NSString) -> [FileItem]? {
        cache.object(forKey: key)?.items
    }

    func store(_ items: [FileItem], forKey key: NSString) {
        cache.setObject(Entry(items: items), forKey: key)
    }

    /// Off-main directory enumeration using the bulk-resource-keys fast
    /// path. Avoids the per-file `lstat` + Launch Services round-trips
    /// that `FileItem(url:)` does, matching `FileExplorerViewModel`'s
    /// regular `loadFiles()` performance characteristics.
    nonisolated static func enumerate(at url: URL, showHidden: Bool) -> [FileItem] {
        let keys = FileItem.prefetchKeys
        let keySet = Set(keys)
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: opts
        ) else { return [] }

        var result: [FileItem] = []
        result.reserveCapacity(contents.count)
        for u in contents {
            let rv = (try? u.resourceValues(forKeys: keySet)) ?? URLResourceValues()
            result.append(FileItem(url: u, resourceValues: rv))
        }
        result.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return result
    }
}

// MARK: - Quick Look
// QuickLookPreview / QuickLookPanelController moved to QuickLookPanelController.swift

// MARK: - Plain Text Preview Floating Panel (`[` / `]`)
// Moved to TextPreviewPanelController.swift

// MARK: - Keyboard Handling (unused modifier kept for backward compat)

