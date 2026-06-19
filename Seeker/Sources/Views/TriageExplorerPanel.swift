import SwiftUI
import AppKit

/// Shared right-hand explorer used by both the Find Duplicates and the
/// Compare Folders windows. It navigates to and highlights a target file
/// passed from the left-hand list, and lets the user browse, preview,
/// open, reveal, or trash files.
///
/// Standard macOS keyboard shortcuts are supported while the window is
/// key: **Space** quick-looks the active file, **⌘⌫** moves it to the
/// Trash. Deleting calls `onDeleted` so the host view can update its own
/// model (duplicate groups / difference lists) without a full re-scan.
struct TriageExplorerPanel: View {
    /// The file the left-hand list asked to focus. Drives navigation and
    /// highlight, and is the fallback target for actions when the user
    /// hasn't clicked a different row inside this panel. Browse mode only.
    var targetURL: URL? = nil
    /// When non-nil the panel runs in **fixed-list** mode: it shows
    /// exactly these files (no folder navigation, no path bar) under a
    /// title header. Used by the compare window to show “only in A” /
    /// “only in B”. When nil the panel runs in browse mode driven by
    /// `targetURL`.
    var fixedURLs: [URL]? = nil
    /// Header title shown in fixed-list mode (e.g. the folder name).
    var headerTitle: String? = nil
    /// Optional single-letter badge (e.g. “A” / “B”) for the header.
    var headerBadge: String? = nil
    var headerBadgeColor: Color = .accentColor
    /// Message shown when the fixed list is empty.
    var emptyMessage: String = "Empty folder"
    /// Invoked after a file is successfully moved to the Trash.
    var onDeleted: ((URL) -> Void)? = nil

    @State private var vm = FileExplorerViewModel()
    /// Cached `FileItem`s for fixed-list mode (rebuilt when `fixedURLs`
    /// changes) so the body doesn't re-`lstat` every file each render.
    @State private var fixedItems: [FileItem] = []
    /// Files selected inside this panel. Supports ⌘-click (toggle) and
    /// ⇧-click (range) like the main explorer. Falls back to `targetURL`
    /// for actions when empty in browse mode.
    @State private var selection: Set<URL> = []
    /// Anchor for ⇧-range selection and the "current" file for
    /// preview/open/reveal (single-file actions).
    @State private var anchorURL: URL?
    @State private var previewURL: URL?
    @State private var showPreview = false
    /// Drives keyboard focus so the list can receive Space / ⌘⌫ key
    /// presses (standard Finder shortcuts).
    @FocusState private var listFocused: Bool
    /// The window hosting this panel, captured so we can tell whether
    /// the app-wide ⌘⌫ menu shortcut was meant for us (i.e. we're key).
    @State private var hostWindow: NSWindow?

    /// Whether this panel shows a fixed list instead of a browsable dir.
    private var isFixed: Bool { fixedURLs != nil }

    /// The files currently displayed (fixed list or browsed directory).
    private var items: [FileItem] { isFixed ? fixedItems : vm.files }

    /// All files the delete action operates on, in display order. Uses
    /// the multi-selection, falling back to `targetURL` in browse mode.
    private var activeURLs: [URL] {
        if !selection.isEmpty {
            return items.map(\.url).filter { selection.contains($0) }
        }
        if !isFixed, let t = targetURL { return [t] }
        return []
    }

    /// The single file that preview / open / reveal act on.
    private var primaryURL: URL? {
        anchorURL ?? activeURLs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if isFixed {
                fixedHeader
            } else {
                pathBar
            }
            Divider()
            actionBar
            Divider()
            if items.isEmpty {
                emptyBody
            } else {
                listBody
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .background(WindowAccessor { hostWindow = $0 })
        .onAppear {
            if isFixed {
                rebuildFixed()
                DispatchQueue.main.async { listFocused = true }
            } else {
                syncToTarget()
            }
        }
        .onChange(of: targetURL) { _, _ in if !isFixed { syncToTarget() } }
        .onChange(of: fixedURLs) { _, _ in rebuildFixed() }
        // ⌘⌫ is an app-wide menu shortcut owned by the main window, so it
        // can't reach our List's `.onKeyPress`. The menu command posts
        // this when a helper window is key; act only if that's us.
        .onReceive(NotificationCenter.default.publisher(for: .triageMoveToTrashRequested)) { _ in
            // Scope to the focused panel (the compare window has two).
            if hostWindow?.isKeyWindow == true, listFocused { deleteActive() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triageSelectAllRequested)) { _ in
            if hostWindow?.isKeyWindow == true, listFocused { selectAllItems() }
        }
        .sheet(isPresented: $showPreview) {
            if let url = previewURL {
                VStack(spacing: 0) {
                    QuickLookPreview(url: url)
                    HStack {
                        Text(url.lastPathComponent)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(url) }
                        Button("Done") { showPreview = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(10)
                }
                .frame(minWidth: 640, minHeight: 460)
            }
        }
        .onChange(of: showPreview) { _, isShowing in
            // Return focus to the list when Quick Look closes so Space
            // can re-open it without an extra click.
            if !isShowing { DispatchQueue.main.async { listFocused = true } }
        }
    }

    private func syncToTarget() {
        guard let url = targetURL else { return }
        selection = [url]
        anchorURL = url
        vm.revealAndSelect(url)
        DispatchQueue.main.async { listFocused = true }
    }

    /// Rebuilds the cached `FileItem`s for fixed-list mode.
    private func rebuildFixed() {
        guard let urls = fixedURLs else { return }
        fixedItems = urls.map { FileItem(url: $0) }
        // Drop any selection that's no longer present in the list.
        let present = Set(urls.map { $0.standardizedFileURL })
        selection = selection.filter { present.contains($0.standardizedFileURL) }
        if let a = anchorURL, !present.contains(a.standardizedFileURL) { anchorURL = nil }
    }

    /// Handles a row click with modifier keys: ⌘ toggles, ⇧ extends a
    /// range from the anchor, plain click selects just that row.
    private func selectRow(_ file: FileItem) {
        let flags = NSEvent.modifierFlags
        let url = file.url
        if flags.contains(.shift), let anchor = anchorURL,
           let from = indexOf(anchor), let to = indexOf(url) {
            let range = from <= to ? from...to : to...from
            selection = Set(items[range].map(\.url))
            // Anchor stays put so the range can be re-dragged.
        } else if flags.contains(.command) {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
            anchorURL = url
        } else {
            selection = [url]
            anchorURL = url
        }
        listFocused = true
    }

    private func indexOf(_ url: URL) -> Int? {
        items.firstIndex { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    /// Opens a file (or navigates into a folder). Mirrors the main
    /// explorer's double-click behaviour. In fixed-list mode there is no
    /// in-panel navigation, so folders open in Finder instead.
    private func open(_ file: FileItem) {
        if isFixed {
            NSWorkspace.shared.open(file.url)
            return
        }
        if file.isDirectory && !file.isPackage {
            selection = []
            anchorURL = nil
            vm.navigateTo(file.url)
        } else {
            vm.openItem(file)
        }
    }

    private func previewActive() {
        guard let url = primaryURL else { return }
        if showPreview {
            showPreview = false
        } else {
            previewURL = url
            showPreview = true
        }
    }

    private func deleteActive() {
        let urls = activeURLs
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        if urls.count == 1 {
            alert.messageText = "Move \u{201C}\(urls[0].lastPathComponent)\u{201D} to Trash?"
        } else {
            alert.messageText = "Move \(urls.count) items to Trash?"
        }
        alert.informativeText = "The selected file\(urls.count == 1 ? "" : "s") will be moved to the Trash. You can recover \(urls.count == 1 ? "it" : "them") from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Clear selection immediately so the UI feels responsive, then do
        // the actual trash off the main thread — `trashItem` is a
        // synchronous syscall that can stall on large files, external
        // disks, or iCloud-evicted items, which froze the window right
        // after the user confirmed.
        selection = []
        anchorURL = nil
        Task {
            let trashed = await Task.detached(priority: .userInitiated) { () -> [URL] in
                var done: [URL] = []
                for url in urls {
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        done.append(url)
                    } catch {
                        print("[Seeker] Failed to trash \(url.path): \(error)")
                    }
                }
                return done
            }.value
            guard !trashed.isEmpty else { return }
            for url in trashed { onDeleted?(url) }
            if !isFixed { vm.loadFiles() }
        }
    }

    /// Prompts for a destination folder and copies or moves the selected
    /// files there via `FileOperationManager` (progress + undo handled by
    /// the shared op manager, same as the main explorer's paste).
    private func copyOrMove(move: Bool) {
        let sources = activeURLs
        guard !sources.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move Here" : "Copy Here"
        panel.message = move
            ? "Choose a destination folder to move \(sources.count) item\(sources.count == 1 ? "" : "s") into"
            : "Choose a destination folder to copy \(sources.count) item\(sources.count == 1 ? "" : "s") into"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let movedURLs = sources
        if move {
            selection = []
            anchorURL = nil
            FileOperationManager.shared.startMove(sources: sources, to: dest) { _ in
                for url in movedURLs { onDeleted?(url) }
                if !isFixed { vm.loadFiles() }
            }
        } else {
            FileOperationManager.shared.startCopy(sources: sources, to: dest) { _ in
                // Copy leaves the originals in place, so the lists don't
                // change; the destination refreshes via the op manager.
            }
        }
    }

    // MARK: - Headers

    /// Title header shown in fixed-list mode in place of the path bar.
    private var fixedHeader: some View {
        HStack(spacing: 6) {
            if let badge = headerBadge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(headerBadgeColor.opacity(0.85)))
            }
            if let title = headerTitle {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(items.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - Path bar

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                vm.navigateTo(vm.currentURL.deletingLastPathComponent())
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Enclosing folder")
            .disabled(vm.currentURL.path == "/")

            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            Text(vm.currentURL.path)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.head)
                .help(vm.currentURL.path)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Listing

    private var emptyBody: some View {
        VStack {
            Spacer()
            Text(emptyMessage)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listBody: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(items) { file in
                    explorerRow(file)
                        .tag(file.url)
                        .id(file.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        // Explicit selection (⌘/⇧ aware) + double-tap open.
                        // List's native focus-dependent highlight is
                        // unreliable here (the compare window has two
                        // lists), so we drive selection ourselves.
                        .onTapGesture(count: 2) { open(file) }
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            selectRow(file)
                        })
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            // Standard Finder keys: Space quick-looks, ⌘⌫ trashes,
            // ⌘A selects everything.
            .onKeyPress(.space) {
                guard primaryURL != nil else { return .ignored }
                previewActive()
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { press in
                guard press.modifiers.contains(.command), !activeURLs.isEmpty else { return .ignored }
                deleteActive()
                return .handled
            }
            .onChange(of: targetURL) { _, _ in if !isFixed { scrollToTarget(proxy) } }
            .onChange(of: vm.files) { _, _ in if !isFixed { scrollToTarget(proxy) } }
        }
    }

    /// Selects every visible file. Anchored on the first item so a
    /// following ⇧-click extends from a sensible point.
    private func selectAllItems() {
        selection = Set(items.map(\.url))
        anchorURL = items.first?.url
        listFocused = true
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let url = targetURL,
              let match = vm.files.first(where: {
                  $0.url.standardizedFileURL.path == url.standardizedFileURL.path
              }) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(match.id, anchor: .center)
            }
        }
    }

    private func explorerRow(_ file: FileItem) -> some View {
        let isTarget = targetURL.map {
            file.url.standardizedFileURL.path == $0.standardizedFileURL.path
        } ?? false
        let isSelected = selection.contains(file.url)
        return HStack(spacing: 7) {
            Image(nsImage: SidebarRow.icon(for: file.url))
                .resizable()
                .frame(width: 16, height: 16)
            Text(file.name)
                .font(.system(size: 11, weight: (isTarget || isSelected) ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(file.isDirectory ? "" : file.formattedSize)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .monospacedDigit()
            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22)
                      : (isTarget ? Color.accentColor.opacity(0.10) : Color.clear))
        )
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 4) {
            // Space → Quick Look. Standard macOS Finder behaviour.
            Button {
                previewActive()
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(primaryURL == nil)
            .help("Quick Look (Space)")

            Button {
                if let url = primaryURL { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(primaryURL == nil)
            .help("Open with the default app")

            Button {
                let urls = activeURLs
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(activeURLs.isEmpty)
            .help("Reveal in Finder")

            Button {
                copyOrMove(move: false)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(activeURLs.isEmpty)
            .help("Copy to a folder\u{2026}")

            Button {
                copyOrMove(move: true)
            } label: {
                Image(systemName: "arrow.right.doc.on.clipboard")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(activeURLs.isEmpty)
            .help("Move to a folder\u{2026}")

            // ⌘⌫ → move to Trash. Standard macOS Finder behaviour.
            Button(role: .destructive) {
                deleteActive()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(activeURLs.isEmpty)
            .help("Move to Trash (\u{2318}\u{232B})")

            Spacer(minLength: 4)

            if activeURLs.count > 1 {
                Text("\(activeURLs.count) selected")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.02))
    }
}

/// Captures the `NSWindow` hosting a SwiftUI view so app-wide handlers
/// can tell whether this view's window is currently key.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
