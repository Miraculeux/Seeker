import SwiftUI
import QuickLookUI
import UniformTypeIdentifiers

// MARK: - File Content View (supports list, icon, column modes)

struct FileContentView: View {
    @Bindable var viewModel: FileExplorerViewModel
    @Environment(AppState.self) var appState
    let side: AppState.PaneSide
    @State private var quickLookURL: URL?
    @State private var showQuickLook = false
    @State private var columnRefresh: Int = 0

    var body: some View {
        Group {
            switch viewModel.viewMode {
            case .list:
                listView
            case .icons:
                iconGridView
            case .columns:
                columnView
            }
        }
        .id(columnRefresh)
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
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .columnSettingsChanged)) { _ in
            columnRefresh += 1
        }
    }

    // MARK: - List View

    private var listView: some View {
        VStack(spacing: 0) {
            // Column header
            listHeader
            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(viewModel.files) { file in
                        FileListRow(
                            file: file,
                            isSelected: isFileSelected(file),
                            isRenaming: viewModel.renamingFile == file,
                            renameText: $viewModel.renameText,
                            onCommitRename: { viewModel.commitRename() },
                            onCancelRename: { viewModel.cancelRename() }
                        )
                        .id(file.id)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isFileSelected(file) ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                        .onTapGesture(count: 2) {
                            viewModel.openItem(file)
                        }
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            unfocusTextFields()
                            let flags = NSEvent.modifierFlags
                            viewModel.handleFileClick(file, command: flags.contains(.command), shift: flags.contains(.shift))
                            appState.activePane = side
                        })
                        .contextMenu { fileContextMenu(for: file) }
                        .onDrag {
                            fileDragProvider(for: file.url)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onChange(of: viewModel.selectedFileIDs) { _, _ in
                    if let file = viewModel.selectedFile {
                        proxy.scrollTo(file.id)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
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
        HStack(spacing: 0) {
            sortableHeader("Name", sortKey: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(SettingsManager.shared.visibleColumnsOrdered) { col in
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
            viewModel.loadFiles()
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

    private func fileDragProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        let data = url.dataRepresentation
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func updateIconGridColumnCount(width: CGFloat) {
        let itemMin: CGFloat = 90
        let spacing: CGFloat = 8
        let padded = width - 24 // 12pt padding on each side
        let count = max(1, Int((padded + spacing) / (itemMin + spacing)))
        viewModel.iconGridColumnCount = count
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 110), spacing: 8)], spacing: 8) {
                ForEach(viewModel.files) { file in
                    FileIconCell(
                        file: file,
                        isSelected: isFileSelected(file),
                        isRenaming: viewModel.renamingFile == file,
                        renameText: $viewModel.renameText,
                        onCommitRename: { viewModel.commitRename() },
                        onCancelRename: { viewModel.cancelRename() }
                    )
                    .onTapGesture(count: 2) {
                        viewModel.openItem(file)
                    }
                    .simultaneousGesture(TapGesture(count: 1).onEnded {
                        unfocusTextFields()
                        let flags = NSEvent.modifierFlags
                        viewModel.handleFileClick(file, command: flags.contains(.command), shift: flags.contains(.shift))
                        appState.activePane = side
                    })
                    .contextMenu { fileContextMenu(for: file) }
                    .onDrag {
                        fileDragProvider(for: file.url)
                    }
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
                }
            )
        }
        .contextMenu { directoryContextMenu }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - Column View

    private var columnView: some View {
        ColumnBrowserView(viewModel: viewModel, side: side)
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func fileContextMenu(for file: FileItem) -> some View {
        Button("Open") { viewModel.openItem(file) }

        if file.isPackage {
            Button("Show Package Contents") { viewModel.navigateTo(file.url) }
        }

        if !file.isDirectory {
            Button("Quick Look") {
                quickLookURL = file.url
                showQuickLook = true
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

        Button("Rename…") { viewModel.beginRename(file) }
        Button("Move to Trash") { viewModel.trashSelected() }

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

        // Collect all URLs first, then perform as a single operation
        final class URLCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var urls = [URL]()
            func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
            var result: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
        }
        let collector = URLCollector()
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let urlString = String(data: data, encoding: .utf8),
                      let sourceURL = URL(string: urlString) else { return }
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

    private func openTerminal(at url: URL) {
        let escapedPath = url.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "tell application \"Terminal\" to do script \"cd '\(escapedPath)'\""
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

// MARK: - List Row

struct FileListRow: View {
    let file: FileItem
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    @State private var hovering = false
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Name column
            HStack(spacing: 7) {
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
                        .onAppear { isRenameFocused = true }
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
            ForEach(SettingsManager.shared.visibleColumnsOrdered) { col in
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
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.03) : Color.clear)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Icon Grid Cell

struct FileIconCell: View {
    let file: FileItem
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    @State private var hovering = false
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: file.nsIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(hovering ? 0.15 : 0.05), radius: hovering ? 4 : 1, y: hovering ? 2 : 1)
                .scaleEffect(hovering ? 1.05 : 1.0)

            if isRenaming {
                TextField("", text: $renameText, onCommit: onCommitRename)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .multilineTextAlignment(.center)
                    .focused($isRenameFocused)
                    .onExitCommand(perform: onCancelRename)
                    .onAppear { isRenameFocused = true }
            } else {
                Text(file.displayName)
                    .font(.system(size: 10, weight: isSelected ? .medium : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
        }
        .frame(width: 90, height: 90)
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
    }
}

// MARK: - Column Browser View

struct ColumnBrowserView: View {
    @Bindable var viewModel: FileExplorerViewModel
    let side: AppState.PaneSide
    @State private var columnPath: [URL] = []
    @State private var columnSelections: [URL: FileItem] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                ForEach(Array(effectiveColumns.enumerated()), id: \.offset) { index, url in
                    VStack(spacing: 0) {
                        columnFileList(for: url, columnIndex: index)
                    }
                    .frame(width: 220)

                    if index < effectiveColumns.count - 1 {
                        Divider()
                    }
                }

                // Preview column for selected file
                if let lastSel = columnSelections[effectiveColumns.last ?? viewModel.currentURL],
                   !lastSel.isDirectory {
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
    }

    private func columnFileList(for directoryURL: URL, columnIndex: Int) -> some View {
        let items = loadItems(at: directoryURL)
        return List(selection: Binding<FileItem?>(
            get: { columnSelections[directoryURL] },
            set: { item in
                columnSelections[directoryURL] = item
                // Trim columns after this one
                if columnIndex == 0 {
                    columnPath = []
                } else {
                    columnPath = Array(columnPath.prefix(columnIndex))
                }
                // If directory, add as next column
                if let item = item, item.isDirectory {
                    columnPath.append(item.url)
                }
                viewModel.selectionAnchor = item
                viewModel.selectedFileIDs = item.map { Set([$0.id]) } ?? []
            }
        )) {
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
                .onTapGesture(count: 2) {
                    viewModel.openItem(file)
                }
            }
        }
        .listStyle(.plain)
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

    private func loadItems(at url: URL) -> [FileItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey],
            options: viewModel.showHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        return contents.map { FileItem(url: $0) }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Quick Look Preview

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as QLPreviewItem
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}

// MARK: - Quick Look Floating Panel (Finder-style)

@MainActor
class QuickLookPanelController: NSObject, @unchecked Sendable, NSWindowDelegate {
    private var panel: NSPanel?
    private var previewView: QLPreviewView?
    private(set) var isVisible: Bool = false

    func togglePreview(for url: URL) {
        if let p = panel, p.isVisible {
            close()
        } else {
            show(url: url)
        }
    }

    func updatePreview(for url: URL) {
        guard isVisible, let p = panel, p.isVisible else { return }
        previewView?.previewItem = url as QLPreviewItem
        panel?.title = url.lastPathComponent
    }

    // Intercept close button — use orderOut instead of close
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            close()
        }
        return false // prevent NSWindow.close() from being called
    }

    private func show(url: URL) {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            p.animationBehavior = .utilityWindow
            p.minSize = NSSize(width: 300, height: 250)
            p.delegate = self

            guard let contentView = p.contentView,
                  let qlView = QLPreviewView(frame: contentView.bounds, style: .normal) else {
                return
            }
            qlView.autoresizingMask = [.width, .height]
            contentView.addSubview(qlView)

            self.panel = p
            self.previewView = qlView
        }

        previewView?.previewItem = url as QLPreviewItem
        panel?.title = url.lastPathComponent

        if let mainWindow = NSApp.mainWindow ?? NSApp.keyWindow {
            let mainFrame = mainWindow.frame
            let panelSize = panel?.frame.size ?? NSSize(width: 600, height: 500)
            let x = mainFrame.midX - panelSize.width / 2
            let y = mainFrame.midY - panelSize.height / 2
            panel?.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel?.center()
        }

        panel?.alphaValue = 0
        panel?.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }

        isVisible = true
        NSApp.mainWindow?.makeKey()
    }

    func close() {
        guard let panel = panel, isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            MainActor.assumeIsolated {
                panel.animator().alphaValue = 0
            }
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }
}

// MARK: - Keyboard Handling (unused modifier kept for backward compat)
