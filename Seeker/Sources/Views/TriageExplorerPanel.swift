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
    /// hasn't clicked a different row inside this panel.
    let targetURL: URL?
    /// Invoked after a file is successfully moved to the Trash.
    var onDeleted: ((URL) -> Void)? = nil

    @State private var vm = FileExplorerViewModel()
    /// The row the user clicked inside this panel. Falls back to
    /// `targetURL` when nil so the action bar / preview always have
    /// something to act on.
    @State private var selectedURL: URL?
    @State private var previewURL: URL?
    @State private var showPreview = false
    /// Drives keyboard focus so the list can receive Space / ⌘⌫ key
    /// presses (standard Finder shortcuts).
    @FocusState private var listFocused: Bool

    /// The file the action bar, preview, and delete operate on.
    private var activeURL: URL? { selectedURL ?? targetURL }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            if vm.files.isEmpty {
                emptyBody
            } else {
                listBody
            }
            Divider()
            actionBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { syncToTarget() }
        .onChange(of: targetURL) { _, _ in syncToTarget() }
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
        selectedURL = url
        vm.revealAndSelect(url)
        DispatchQueue.main.async { listFocused = true }
    }

    /// Opens a file (or navigates into a folder). Mirrors the main
    /// explorer's double-click behaviour.
    private func open(_ file: FileItem) {
        if file.isDirectory && !file.isPackage {
            selectedURL = nil
            vm.navigateTo(file.url)
        } else {
            vm.openItem(file)
        }
    }

    private func previewActive() {
        guard let url = activeURL else { return }
        if showPreview {
            showPreview = false
        } else {
            previewURL = url
            showPreview = true
        }
    }

    private func deleteActive() {
        guard let url = activeURL else { return }
        let alert = NSAlert()
        alert.messageText = "Move \u{201C}\(url.lastPathComponent)\u{201D} to Trash?"
        alert.informativeText = "The file will be moved to the Trash. You can recover it from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            selectedURL = nil
            onDeleted?(url)
            vm.loadFiles()
        } catch {
            print("[Seeker] Failed to trash \(url.path): \(error)")
        }
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
            Text("Empty folder")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listBody: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedURL) {
                ForEach(vm.files) { file in
                    explorerRow(file)
                        .tag(file.url)
                        .id(file.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        // List handles single-click selection natively;
                        // add double-click to open without blocking it.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { open(file) })
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            // Standard Finder keys: Space quick-looks, ⌘⌫ trashes.
            .onKeyPress(.space) {
                guard activeURL != nil else { return .ignored }
                previewActive()
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { press in
                guard press.modifiers.contains(.command), activeURL != nil else { return .ignored }
                deleteActive()
                return .handled
            }
            .onChange(of: targetURL) { _, _ in scrollToTarget(proxy) }
            .onChange(of: vm.files) { _, _ in scrollToTarget(proxy) }
        }
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
        return HStack(spacing: 7) {
            Image(nsImage: SidebarRow.icon(for: file.url))
                .resizable()
                .frame(width: 16, height: 16)
            Text(file.name)
                .font(.system(size: 11, weight: isTarget ? .semibold : .regular))
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
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            // Space → Quick Look. Standard macOS Finder behaviour.
            Button {
                previewActive()
            } label: {
                Label("Preview", systemImage: "eye")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(activeURL == nil)
            .help("Quick Look (Space)")

            Button {
                if let url = activeURL { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(activeURL == nil)
            .help("Open with the default app")

            Button {
                if let url = activeURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: {
                Label("Reveal", systemImage: "macwindow")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(activeURL == nil)
            .help("Reveal in Finder")

            // ⌘⌫ → move to Trash. Standard macOS Finder behaviour.
            Button(role: .destructive) {
                deleteActive()
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(activeURL == nil)
            .help("Move to Trash (\u{2318}\u{232B})")

            Spacer()

            if let url = activeURL {
                Text(url.lastPathComponent)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }
}
