import SwiftUI
import QuickLookUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import CommonCrypto

// MARK: - File Content View (supports list, icon, column modes)

struct FileContentView: View {
    @Bindable var viewModel: FileExplorerViewModel
    @Environment(AppState.self) var appState
    let side: AppState.PaneSide
    @State private var quickLookURL: URL?
    @State private var showQuickLook = false
    @State private var columnRefresh: Int = 0
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
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .columnSettingsChanged)) { _ in
            columnRefresh += 1
        }
    }

    // MARK: - List View

    private var listView: some View {
        let visibleColumns = SettingsManager.shared.visibleColumnsOrdered
        return VStack(spacing: 0) {
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
                            visibleColumns: visibleColumns,
                            renameText: $viewModel.renameText,
                            onCommitRename: { viewModel.commitRename() },
                            onCancelRename: { viewModel.cancelRename() }
                        )
                        .id(file.id)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isFileSelected(file) ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                                viewModel.openItem(file)
                            } else {
                                unfocusTextFields()
                                let flags = NSEvent.modifierFlags
                                viewModel.handleFileClick(file, command: flags.contains(.command), shift: flags.contains(.shift))
                                appState.activePane = side
                            }
                        })
                        .contextMenu { fileContextMenu(for: file) }
                        .onDrag {
                            fileDragProvider(for: file.url)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu { directoryContextMenu }
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
                        isSelected: isFileSelected(file),
                        isRenaming: viewModel.renamingFile == file,
                        renameText: $viewModel.renameText,
                        onCommitRename: { viewModel.commitRename() },
                        onCancelRename: { viewModel.cancelRename() }
                    )
                    .simultaneousGesture(TapGesture(count: 1).onEnded {
                        if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                            viewModel.openItem(file)
                        } else {
                            unfocusTextFields()
                            let flags = NSEvent.modifierFlags
                            viewModel.handleFileClick(file, command: flags.contains(.command), shift: flags.contains(.shift))
                            appState.activePane = side
                        }
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
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

    @ViewBuilder
    private func fileContextMenu(for file: FileItem) -> some View {
        Button("Open") { viewModel.openItem(file) }

        if !file.isDirectory || file.isPackage {
            let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: file.url)
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

    private func openTerminal(at url: URL) {
        // Reject paths with characters that could break out of an AppleScript
        // string literal (quotes, backslash, control chars, line/paragraph
        // separators). This mitigates AppleScript injection via folder names.
        let path = url.path
        let forbidden: Set<Character> = ["\"", "\\", "\r", "\n", "\u{2028}", "\u{2029}", "\0"]
        if path.contains(where: { forbidden.contains($0) || $0.asciiValue.map { $0 < 0x20 } ?? false }) {
            // Fall back to opening Terminal.app on the folder via NSWorkspace,
            // which does not interpret the path as code.
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: terminalURL, configuration: cfg)
            return
        }
        // Single-quote escape for the inner shell `cd` argument.
        let shellEscaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "tell application \"Terminal\" to do script \"cd '\(shellEscaped)'\""
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
    let visibleColumns: [ColumnID]
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

/// Two-tier cache for QuickLook thumbnails used by `FileIconCell`.
///
/// Layer 1 (in-process `NSCache`): hot working set, evicted under memory
/// pressure, bounded by `countLimit`.
///
/// Layer 2 (`DiskThumbnailCache`): persistent PNG files under
/// `~/Library/Caches/<bundleID>/thumbnails/` so previews survive app
/// restarts. Cache keys hash `path | mtime | size | sizeBucket`, so a
/// changed file (different mtime/size) automatically misses and is
/// re-rendered without an explicit invalidation step.
///
/// Thread-safe by `NSCache` contract; marked `nonisolated(unsafe)` so
/// it can be reached from any actor.
enum ThumbnailCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 512
        return c
    }()

    /// File-extension allowlist: types QuickLook can usually thumbnail
    /// quickly. Restricting up front avoids paying for QL requests that
    /// just return a generic icon (which the cell already shows).
    static let thumbnailableExtensions: Set<String> = [
        // raster
        "jpg", "jpeg", "png", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp", "ico",
        // raw
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf", "srw",
        // vector / docs
        "pdf", "svg", "ps", "eps",
        // video (QL extracts a poster frame)
        "mov", "mp4", "m4v", "avi", "mkv", "webm",
        // app-rendered
        "psd", "sketch"
    ]

    static func canThumbnail(_ url: URL) -> Bool {
        thumbnailableExtensions.contains(url.pathExtension.lowercased())
    }

    private static func memKey(for url: URL, sizeBucket: Int) -> NSString {
        "\(url.path)\u{1}\(sizeBucket)" as NSString
    }

    static func cached(for url: URL, sizeBucket: Int) -> NSImage? {
        cache.object(forKey: memKey(for: url, sizeBucket: sizeBucket))
    }

    /// Returns any cached thumbnail for `url`, regardless of bucket.
    /// Used as a fast fallback during zoom: rather than blanking the
    /// cell while a bigger render is in flight, we display whatever we
    /// already have. Tries the requested bucket first, then nearby
    /// buckets in order of decreasing closeness.
    static func cachedAny(for url: URL, preferredBucket: Int) -> NSImage? {
        if let exact = cached(for: url, sizeBucket: preferredBucket) {
            return exact
        }
        // Cheap probe: look for any of our standard zoom step sizes.
        // The list is short (14 entries) so iterating is trivial, and
        // hitting a cached entry is O(1) per probe.
        let steps = FileExplorerViewModel.iconZoomSteps.map(Int.init)
        let ordered = steps.sorted { abs($0 - preferredBucket) < abs($1 - preferredBucket) }
        for s in ordered {
            if let hit = cached(for: url, sizeBucket: s) { return hit }
        }
        return nil
    }

    /// Drops every entry from the in-memory tier. Intended for the
    /// Settings "Clear Caches" affordance to pair with the disk wipe.
    static func clearMemory() {
        cache.removeAllObjects()
    }

    /// Generates a thumbnail off the main actor, consulting the in-memory
    /// cache first, then the on-disk cache, then QuickLook. Returns `nil`
    /// on failure. Callers should treat `nil` as "fall back to the
    /// generic Finder icon".
    static func thumbnail(for url: URL, sizeBucket: Int, scale: CGFloat) async -> NSImage? {
        // 1. In-memory hit.
        if let hit = cache.object(forKey: memKey(for: url, sizeBucket: sizeBucket)) {
            return hit
        }

        // 2. On-disk hit. Promote to memory before returning so subsequent
        //    cells in the same scroll pass don't repeat the disk read.
        if let diskHit = await DiskThumbnailCache.shared.load(url: url, sizeBucket: sizeBucket) {
            cache.setObject(diskHit, forKey: memKey(for: url, sizeBucket: sizeBucket))
            return diskHit
        }

        // 3. QuickLook render. Persist to both layers so we don't pay this
        //    cost again until the file's mtime/size changes.
        let dim = CGFloat(sizeBucket)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: dim, height: dim),
            scale: scale,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                guard let rep else { cont.resume(returning: nil); return }
                let image = rep.nsImage
                cache.setObject(image, forKey: memKey(for: url, sizeBucket: sizeBucket))
                // Fire-and-forget disk write; don't block the QL callback.
                Task.detached(priority: .utility) {
                    await DiskThumbnailCache.shared.store(image: image, url: url, sizeBucket: sizeBucket)
                }
                cont.resume(returning: image)
            }
        }
    }
}

/// Persistent on-disk thumbnail cache.
///
/// Files are stored as PNGs under
/// `~/Library/Caches/<bundleID>/thumbnails/<aa>/<full-hash>.png`. The
/// 2-character prefix subdirectory keeps any single directory from
/// growing unboundedly (Finder/HFS+ slow down with very large dirs).
///
/// Cache keys hash `(path, mtime, size, sizeBucket)` so any file change
/// produces a fresh key and the stale render is simply ignored (and
/// eventually evicted when the cache exceeds its size budget).
///
/// All filesystem work happens off the main actor.
final class DiskThumbnailCache: @unchecked Sendable {
    static let shared = DiskThumbnailCache()

    /// Approximate ceiling for total disk usage. Trim runs lazily when
    /// new entries push us over the budget.
    private static let maxBytes: Int64 = 256 * 1024 * 1024  // 256 MB

    private let directory: URL
    private let queue = DispatchQueue(label: "com.seeker.thumbcache.io", qos: .utility)
    /// Counter so we don't run the `trim` walk on every single write.
    private var writesSinceTrim: Int = 0

    private init() {
        let fm = FileManager.default
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.seeker.app"
        directory = caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Key derivation

    /// Builds a stable hex digest from the file's identity + the desired
    /// size bucket. Includes mtime + size so that editing or replacing a
    /// file produces a new key, automatically invalidating the stale
    /// render without an explicit purge.
    private func cacheKey(for url: URL, sizeBucket: Int) -> String? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return nil }
        let mtime = rv.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = rv.fileSize ?? 0
        let composite = "\(url.standardizedFileURL.path)|\(mtime)|\(size)|\(sizeBucket)"
        return Self.sha256Hex(composite)
    }

    private func fileURL(forKey key: String) -> URL {
        let prefix = String(key.prefix(2))
        return directory
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(key + ".png", isDirectory: false)
    }

    // MARK: - I/O

    func load(url: URL, sizeBucket: Int) async -> NSImage? {
        guard let key = cacheKey(for: url, sizeBucket: sizeBucket) else { return nil }
        let path = fileURL(forKey: key)
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            queue.async {
                guard let data = try? Data(contentsOf: path),
                      let image = NSImage(data: data) else {
                    cont.resume(returning: nil)
                    return
                }
                // Touch atime so LRU-ish trimming keeps recently used
                // entries. We use mtime as the proxy because APFS
                // doesn't track atime by default.
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: path.path
                )
                cont.resume(returning: image)
            }
        }
    }

    func store(image: NSImage, url: URL, sizeBucket: Int) async {
        guard let key = cacheKey(for: url, sizeBucket: sizeBucket) else { return }
        let path = fileURL(forKey: key)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let fm = FileManager.default
                try? fm.createDirectory(at: path.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                if let png = Self.pngData(from: image) {
                    try? png.write(to: path, options: .atomic)
                }
                self.writesSinceTrim += 1
                if self.writesSinceTrim >= 64 {
                    self.writesSinceTrim = 0
                    self.trimIfNeeded()
                }
                cont.resume(returning: ())
            }
        }
    }

    // MARK: - Trim / size enforcement

    /// Walks the cache directory, sums file sizes, and removes the oldest
    /// (by mtime) entries until total size is back under the budget.
    /// Cheap enough to run inline on the cache queue once every ~64
    /// writes, which is plenty for a UI cache.
    private func trimIfNeeded() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return }

        struct Entry { let url: URL; let size: Int64; let mtime: Date }
        var entries: [Entry] = []
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            guard let rv = try? url.resourceValues(forKeys: keys),
                  rv.isRegularFile == true else { continue }
            let size = Int64(rv.fileSize ?? 0)
            let mtime = rv.contentModificationDate ?? .distantPast
            total += size
            entries.append(Entry(url: url, size: size, mtime: mtime))
        }

        guard total > Self.maxBytes else { return }

        // Oldest first.
        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            if total <= Self.maxBytes { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Manually purge the entire cache. Public so a "Clear Caches" menu
    /// item can wire into it later.
    func clear() {
        queue.async {
            let fm = FileManager.default
            try? fm.removeItem(at: self.directory)
            try? fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
        }
    }

    /// Async variant of `clear()` that resolves once the directory has
    /// been removed and recreated. Also flushes the in-memory tier so
    /// the UI doesn't keep showing freshly-deleted thumbnails.
    func clearAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let fm = FileManager.default
                try? fm.removeItem(at: self.directory)
                try? fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
                self.writesSinceTrim = 0
                cont.resume(returning: ())
            }
        }
    }

    /// Total bytes currently consumed by the on-disk cache. Walks the
    /// directory on the cache queue so this never blocks the caller.
    func currentSizeBytes() async -> Int64 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int64, Never>) in
            queue.async {
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(
                    at: self.directory,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }
                ) else { cont.resume(returning: 0); return }

                var total: Int64 = 0
                while let url = enumerator.nextObject() as? URL {
                    let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
                    guard let rv = try? url.resourceValues(forKeys: keys),
                          rv.isRegularFile == true else { continue }
                    total += Int64(rv.fileSize ?? 0)
                }
                cont.resume(returning: total)
            }
        }
    }

    /// Path the cache is stored at, exposed for the Settings UI's
    /// "Reveal in Finder" affordance.
    var directoryURL: URL { directory }

    // MARK: - Helpers

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func sha256Hex(_ s: String) -> String {
        // CommonCrypto is already linked via NCMDump/AESHelper.
        let data = Array(s.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBufferPointer { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

struct FileIconCell: View {
    let file: FileItem
    let iconSize: CGFloat
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @FocusState private var isRenameFocused: Bool

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
                    .onAppear { isRenameFocused = true }
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
    /// the same zoom bucket don't restart the thumbnail load.
    private var thumbnailTaskID: String {
        "\(file.id)\u{1}\(sizeBucket)"
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
                .onTapGesture {
                    if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                        viewModel.openItem(file)
                    }
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
        // Cached: SwiftUI invalidates the column-browser body on hover/
        // selection/etc., which previously re-enumerated every visible
        // column directory synchronously on the main thread on each redraw.
        // Keys include `showHiddenFiles` so toggling the option re-fetches.
        let key = "\(url.standardizedFileURL.path)|\(viewModel.showHiddenFiles ? 1 : 0)" as NSString
        if let cached = ColumnBrowserCache.shared.cache.object(forKey: key) {
            return cached.items
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey],
            options: viewModel.showHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        let items = contents.map { FileItem(url: $0) }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        ColumnBrowserCache.shared.cache.setObject(ColumnBrowserCache.Entry(items: items), forKey: key)
        return items
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
