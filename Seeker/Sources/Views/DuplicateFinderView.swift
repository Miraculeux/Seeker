import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sheet that scans a chosen folder for duplicate files using
/// `DuplicateFinder` (size \u2192 4 KB head xxHash3 \u2192 full-file xxHash3)
/// and lets the user reveal or trash redundant copies.
struct DuplicateFinderView: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    @State private var finder = DuplicateFinder()
    /// Per-group: which URLs the user has selected to delete. The first
    /// item in each group is kept by default; the rest are pre-checked.
    @State private var toDelete: Set<URL> = []
    @State private var expanded: Set<URL> = []
    @State private var resultDirectories: [DuplicateResultDirectory] = []
    @State private var groupNumbers: [UUID: Int] = [:]
    @State private var locateURL: URL?
    /// Root directories being scanned. Mutable so the user can add (via
    /// the "+" button or drag-and-drop) or remove folders and re-scan.
    /// Order encodes keep-priority — earlier roots win.
    @State private var roots: [URL]
    /// True while a folder is hovered over the window during a drag.
    @State private var isDropTargeted = false
    /// The duplicate file the user clicked in the left list; drives the
    /// embedded explorer on the right to navigate to and highlight it.
    @State private var focusedURL: URL?
    @State private var deletionTask: Task<Void, Never>?
    @State private var deletionCompleted = 0
    @State private var deletionTotal = 0
    @State private var deletionError: String?

    init(rootURLs: [URL]) {
        _roots = State(initialValue: rootURLs)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rootsBar
                .disabled(deletionTask != nil)
            Divider()
            Group {
                switch finder.status {
                case .idle:
                    introState
                case .scanning, .hashingHeads, .hashingFull:
                    progressState
                case .done:
                    if finder.groups.isEmpty {
                        emptyState
                    } else {
                        resultsState
                    }
                case .cancelled:
                    cancelledState
                case .failed(let msg):
                    Text("Scan failed: \(msg)")
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(deletionTask != nil)

            Divider()
            footer
        }
        .frame(minWidth: 940, idealWidth: 1100, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .toolWindowURLs(roots)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard deletionTask == nil else { return false }
            return handleFolderDrop(providers)
        }
        .onAppear {
            finder.scan(roots: roots)
            initializePreselection()
        }
        .onChange(of: finder.status) { _, newValue in
            if case .done = newValue { initializePreselection() }
        }
        .onChange(of: finder.groups.map(\.urls)) { _, _ in
            refreshResultDirectories()
        }
        .onDisappear {
            finder.cancel()
            deletionTask?.cancel()
        }
        .alert("Some files could not be moved to Trash", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Find Duplicates")
                    .font(.system(size: 13, weight: .semibold))
                Text(rootSubtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(roots.map(\.path).joined(separator: "\n"))
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - Roots bar

    /// Shows each scanned root as a removable chip (numbered by keep-
    /// priority) plus an "Add Folder" control. Editing the list re-runs
    /// the scan. Folders can also be dropped anywhere on the window.
    private var rootsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(roots.enumerated()), id: \.element) { idx, url in
                    rootChip(index: idx, url: url)
                }
                Button {
                    promptAddFolders()
                } label: {
                    Label("Add Folder", systemImage: "plus")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color.primary.opacity(0.02))
    }

    private func rootChip(index: Int, url: URL) -> some View {
        HStack(spacing: 5) {
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.accentColor.opacity(0.8)))
                .help("Keep priority \(index + 1)")
            Image(systemName: "folder.fill")
                .font(.system(size: 9))
                .foregroundColor(.accentColor)
            Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .help(url.path)
            if roots.count > 1 {
                Button {
                    removeRoot(url)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from scan")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    // MARK: - States

    private var introState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Preparing\u{2026}")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var progressState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.accentColor.opacity(0.7))
            Text(statusTitle)
                .font(.system(size: 13, weight: .medium))
            Text(statusDetail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .monospacedDigit()
            if let fraction = statusFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 280)
            }
            Spacer()
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundColor(.green.opacity(0.7))
            Text("No duplicates found")
                .font(.system(size: 13, weight: .semibold))
            Text("Every file in this location is unique.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var cancelledState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "stop.circle")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Scan cancelled")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var resultsState: some View {
        HSplitView {
            duplicateList
                .frame(minWidth: 360, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            TriageExplorerPanel(
                targetURL: focusedURL,
                onDeleted: { url in removeFromGroups(url) }
            )
            .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var duplicateList: some View {
        let selectedGroupID = finder.groups.first { group in
            focusedURL.map { group.urls.contains($0) } ?? false
        }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    summaryBanner
                    ForEach(resultDirectories) { directory in
                        DuplicateDirectoryRow(
                            directory: directory,
                            isExpanded: expanded.contains(directory.id),
                            toDelete: $toDelete,
                            focusedURL: $focusedURL,
                            selectedGroupID: selectedGroupID,
                            locateURL: locateURL,
                            onLocate: { url in
                                expanded.insert(url.deletingLastPathComponent().standardizedFileURL)
                                focusedURL = url
                                locateURL = url
                            },
                            onLocateReady: { url in
                                proxy.scrollTo(url, anchor: .center)
                                locateURL = nil
                            },
                            onToggleExpand: {
                                if expanded.contains(directory.id) {
                                    expanded.remove(directory.id)
                                } else {
                                    expanded.insert(directory.id)
                                }
                            },
                            onSelect: { url in
                                focusedURL = url
                            }
                        )
                        .id(directory.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: locateURL) { _, url in
                if let url {
                    // First materialize the lazy directory, then the target
                    // file's task scrolls precisely after expansion.
                    proxy.scrollTo(url.deletingLastPathComponent().standardizedFileURL, anchor: .top)
                }
            }
        }
    }

    private var summaryBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(finder.groups.count) duplicate group\(finder.groups.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                Text("Reclaimable: \(ByteCountFormatter.string(fromByteCount: finder.totalReclaimableBytes, countStyle: .file))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(toDelete.count) selected for deletion")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if deletionTask != nil {
                ProgressView(value: Double(deletionCompleted), total: Double(max(1, deletionTotal)))
                    .frame(width: 100)
                Text("Trashing \(deletionCompleted) / \(deletionTotal)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                Button("Stop") { deletionTask?.cancel() }
            } else if case .scanning = finder.status {
                Button("Cancel") { finder.cancel() }
            } else if case .hashingHeads = finder.status {
                Button("Cancel") { finder.cancel() }
            } else if case .hashingFull = finder.status {
                Button("Cancel") { finder.cancel() }
            }
            Spacer()
            Text(footerSelectionSummary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()
            Button("Move to Trash") {
                trashSelected()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(toDelete.isEmpty || deletionTask != nil)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footerSelectionSummary: String {
        let bytes = finder.groups.reduce(Int64(0)) { acc, group in
            acc + Int64(group.urls.filter { toDelete.contains($0) }.count) * group.fileSize
        }
        return "\(toDelete.count) files \u{00B7} \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    // MARK: - Status text helpers

    private var rootSubtitle: String {
        switch roots.count {
        case 0: return ""
        case 1: return roots[0].path
        default:
            return "\(roots.count) locations \u{00B7} scanned as one pool"
        }
    }

    private var statusTitle: String {
        switch finder.status {
        case .scanning: return "Scanning files"
        case .hashingHeads: return "Hashing file headers"
        case .hashingFull: return "Hashing full files"
        default: return ""
        }
    }

    private var statusDetail: String {
        switch finder.status {
        case .scanning(let scanned):
            return "\(scanned) examined"
        case .hashingHeads(let done, let total):
            return "\(done) / \(total)"
        case .hashingFull(let done, let total, let bytes, let totalBytes):
            let pct = totalBytes > 0 ? Int(Double(bytes) / Double(totalBytes) * 100) : 0
            return "\(done) / \(total) files \u{00B7} \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) (\(pct)%)"
        default:
            return ""
        }
    }

    private var statusFraction: Double? {
        switch finder.status {
        case .hashingHeads(let done, let total):
            return total > 0 ? Double(done) / Double(total) : nil
        case .hashingFull(_, _, let bytes, let totalBytes):
            return totalBytes > 0 ? Double(bytes) / Double(totalBytes) : nil
        default:
            return nil
        }
    }

    // MARK: - Root management

    /// Opens a folder picker (multi-select) and appends any new folders
    /// to the scan, then re-runs.
    private func promptAddFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Scan"
        panel.message = "Choose folders to include in the duplicate scan"
        if panel.runModal() == .OK {
            addRoots(panel.urls)
        }
    }

    /// Appends folders that aren't already present (or nested under an
    /// existing root) and re-runs the scan. New roots go to the end, so
    /// they get the lowest keep-priority.
    private func addRoots(_ urls: [URL]) {
        var changed = false
        for url in urls {
            let std = url.standardizedFileURL
            let isDir = (try? std.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            if roots.contains(where: { $0.standardizedFileURL == std }) { continue }
            roots.append(std)
            changed = true
        }
        if changed { rescan() }
    }

    private func removeRoot(_ url: URL) {
        guard roots.count > 1 else { return }
        roots.removeAll { $0 == url }
        rescan()
    }

    private func rescan() {
        guard deletionTask == nil else { return }
        toDelete = []
        expanded = []
        resultDirectories = []
        groupNumbers = [:]
        locateURL = nil
        focusedURL = nil
        finder.scan(roots: roots)
    }

    /// Accepts folder URLs dropped onto the window.
    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let collector = URLCollector()
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                collector.append(url)
            }
        }
        group.notify(queue: .main) {
            let urls = collector.snapshot()
            if !urls.isEmpty { addRoots(urls) }
        }
        return handled
    }

    // MARK: - Actions

    /// Pre-check every URL except the first in each group: a sensible
    /// default that lets the user just hit "Move to Trash" if they
    /// trust the heuristic. Preserve the finder's root-priority/path order,
    /// independently of the directory/name ordering used for display.
    private func initializePreselection() {
        var pre: Set<URL> = []
        for group in finder.groups {
            // Keep the first (sorted by path), mark rest for deletion.
            for url in group.urls.dropFirst() {
                pre.insert(url)
            }
        }
        toDelete = pre
        refreshResultDirectories()
        // Auto-expand the first directory and surface its first file in the
        // explorer so the right pane isn't blank on first results.
        if let first = resultDirectories.first {
            expanded.insert(first.id)
            if focusedURL == nil { focusedURL = first.files.first?.url }
        }
    }

    private func refreshResultDirectories() {
        if finder.groups.isEmpty { groupNumbers = [:] }
        resultDirectories = DuplicateResultDirectory.grouped(finder.groups, previousNumbers: groupNumbers)
        for directory in resultDirectories {
            for file in directory.files { groupNumbers[file.groupID] = file.groupNumber }
        }
        expanded.formIntersection(Set(resultDirectories.map(\.id)))
        let remaining = Set(resultDirectories.flatMap { $0.files.map(\.url) })
        toDelete.formIntersection(remaining)
        if let focusedURL, !remaining.contains(focusedURL) { self.focusedURL = nil }
        if let locateURL, !remaining.contains(locateURL) { self.locateURL = nil }
    }

    private func trashSelected() {
        let urls = Array(toDelete)
        guard !urls.isEmpty, deletionTask == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(urls.count) duplicate\(urls.count == 1 ? "" : "s") to Trash?"
        alert.informativeText = "The selected files will be moved to the Trash. You can recover them from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        deletionCompleted = 0
        deletionTotal = urls.count
        deletionError = nil
        deletionTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                var trashed: Set<URL> = []
                var errors: [String] = []
                var failed = 0
                var lastProgress = ContinuousClock.now
                for (index, url) in urls.enumerated() {
                    if Task.isCancelled { break }
                    do {
                        _ = try TrashRestoreService.shared.trash(url)
                        trashed.insert(url)
                    } catch {
                        failed += 1
                        if errors.count < 10 {
                            errors.append("\(url.path): \(error.localizedDescription)")
                        }
                    }
                    let now = ContinuousClock.now
                    if now - lastProgress >= .milliseconds(100) || index + 1 == urls.count {
                        let completed = index + 1
                        await MainActor.run { deletionCompleted = completed }
                        lastProgress = now
                    }
                }
                return (trashed: trashed, errors: errors, failed: failed)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            // Even a cancelled batch must reconcile operations already completed.
            let removed = Set(result.trashed.map(\.standardizedFileURL))
            finder.groups = finder.groups.compactMap { $0.removing(removed) }
            toDelete.subtract(result.trashed)
            if let focusedURL, result.trashed.contains(focusedURL) { self.focusedURL = nil }
            if result.failed > 0 {
                deletionError = "\(result.failed) file(s) failed.\n" + result.errors.joined(separator: "\n")
            }
            deletionTask = nil
            if !result.trashed.isEmpty {
                NotificationCenter.default.post(name: .filesDidChange, object: nil)
            }
        }
    }

    /// Drops a single file (trashed from the embedded explorer panel)
    /// from the displayed groups, collapsing any group that no longer
    /// has \u2265 2 members. Keeps the left list in sync with the right
    /// panel's delete action.
    private func removeFromGroups(_ url: URL) {
        let std = url.standardizedFileURL
        finder.groups = finder.groups.compactMap { $0.removing([std]) }
        toDelete.remove(url)
        if focusedURL?.standardizedFileURL == std { focusedURL = nil }
        NotificationCenter.default.post(name: .filesDidChange, object: nil)
    }
}

struct DuplicateDirectoryRow: View {
    let directory: DuplicateResultDirectory
    let isExpanded: Bool
    @Binding var toDelete: Set<URL>
    @Binding var focusedURL: URL?
    let selectedGroupID: UUID?
    let locateURL: URL?
    let onLocate: (URL) -> Void
    let onLocateReady: (URL) -> Void
    let onToggleExpand: () -> Void
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleExpand) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(directory.name)
                            .font(.system(size: 11, weight: .medium))
                        Text(directory.url.path)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(directory.url.path)
                    Spacer()
                    Text("\(directory.files.count) files")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(directory.files) { file in
                        DuplicateFileRow(
                            file: file, toDelete: $toDelete,
                            isFocused: focusedURL == file.url,
                            isRelated: selectedGroupID == file.groupID && focusedURL != file.url,
                            onSelect: { onSelect(file.url) }, onLocate: onLocate
                        )
                        .id(file.url)
                        .task(id: locateURL) {
                            guard locateURL == file.url else { return }
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            onLocateReady(file.url)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

struct DuplicateFileRow: View {
    let file: DuplicateResultDirectory.File
    @Binding var toDelete: Set<URL>
    let isFocused: Bool
    let isRelated: Bool
    let onSelect: () -> Void
    let onLocate: (URL) -> Void
    @State private var showCopies = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { toDelete.contains(file.url) },
                set: { checked in
                    if checked { toDelete.insert(file.url) } else { toDelete.remove(file.url) }
                }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .accessibilityLabel("Select \(file.url.lastPathComponent) for deletion")

            if file.isSuggestedKeep && !toDelete.contains(file.url) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.yellow)
                    .help("Suggested keep")
            }

            VStack(alignment: .leading, spacing: 3) {
                Button(action: onSelect) {
                    Text(file.url.lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(file.url.path)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Button { showCopies = true } label: {
                        Label("\(file.groupLabel) \u{00B7} \(file.copies.count) copies", systemImage: "link")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Show all files with identical content")
                    .popover(isPresented: $showCopies) {
                        DuplicateCopiesView(file: file, toDelete: toDelete) { url in
                            showCopies = false
                            onLocate(url)
                        }
                    }
                }
            }
            if isFocused || isRelated {
                Image(systemName: isFocused ? "arrow.right.circle.fill" : "link")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                    .help(isFocused ? "Shown in explorer" : "Identical to the selected file")
                    .accessibilityLabel(isFocused ? "Shown in explorer" : "Identical to the selected file")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isFocused ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isRelated ? Color.accentColor.opacity(0.5) : .clear)
                .allowsHitTesting(false)
        }
    }
}

struct DuplicateCopiesView: View {
    let file: DuplicateResultDirectory.File
    let toDelete: Set<URL>
    let onLocate: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(file.groupLabel) \u{00B7} \(file.copies.count) identical files")
                .font(.headline)
            Text("\(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)) each")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(file.copies, id: \.self) { url in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                if toDelete.contains(url) {
                                    Label("Selected for deletion", systemImage: "checkmark.square.fill")
                                } else if url == file.suggestedKeep {
                                    Label("Suggested keep", systemImage: "star.fill")
                                } else {
                                    Label("Not selected for deletion", systemImage: "square")
                                }
                                Text(url.lastPathComponent).fontWeight(.medium)
                                Text(url.path)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Locate") { onLocate(url) }
                                .accessibilityLabel("Locate \(url.path)")
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 480, height: min(440, 100 + CGFloat(file.copies.count) * 100))
    }
}

/// Thread-safe accumulator for URLs gathered from concurrent
/// `NSItemProvider` callbacks during a drag-and-drop.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    func snapshot() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}
