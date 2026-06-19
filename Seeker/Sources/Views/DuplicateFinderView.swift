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
    /// Group IDs whose detail rows are expanded.
    @State private var expanded: Set<UUID> = []
    /// Root directories being scanned. Mutable so the user can add (via
    /// the "+" button or drag-and-drop) or remove folders and re-scan.
    /// Order encodes keep-priority — earlier roots win.
    @State private var roots: [URL]
    /// True while a folder is hovered over the window during a drag.
    @State private var isDropTargeted = false
    /// The duplicate file the user clicked in the left list; drives the
    /// embedded explorer on the right to navigate to and highlight it.
    @State private var focusedURL: URL?

    init(rootURLs: [URL]) {
        _roots = State(initialValue: rootURLs)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rootsBar
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

            Divider()
            footer
        }
        .frame(minWidth: 940, idealWidth: 1100, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFolderDrop(providers)
        }
        .onAppear {
            finder.scan(roots: roots)
            initializePreselection()
        }
        .onChange(of: finder.status) { _, newValue in
            if case .done = newValue { initializePreselection() }
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
        ScrollView {
            LazyVStack(spacing: 4) {
                summaryBanner
                ForEach(finder.groups) { group in
                    DuplicateGroupRow(
                        group: group,
                        isExpanded: expanded.contains(group.id),
                        toDelete: $toDelete,
                        focusedURL: $focusedURL,
                        onToggleExpand: {
                            if expanded.contains(group.id) {
                                expanded.remove(group.id)
                            } else {
                                expanded.insert(group.id)
                            }
                        },
                        onSelect: { url in
                            focusedURL = url
                        }
                    )
                }
            }
            .padding(8)
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
            if case .scanning = finder.status {
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
            .disabled(toDelete.isEmpty)
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
        toDelete = []
        expanded = []
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
    /// trust the heuristic. The first item per group is kept by
    /// alphabetical order (stable across re-scans of the same folder).
    private func initializePreselection() {
        var pre: Set<URL> = []
        for group in finder.groups {
            // Keep the first (sorted by path), mark rest for deletion.
            for url in group.urls.dropFirst() {
                pre.insert(url)
            }
        }
        toDelete = pre
        // Auto-expand the first group and surface its first file in the
        // explorer so the right pane isn't blank on first results.
        if let first = finder.groups.first {
            expanded.insert(first.id)
            if focusedURL == nil { focusedURL = first.urls.first }
        }
    }

    private func trashSelected() {
        let urls = Array(toDelete)
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(urls.count) duplicate\(urls.count == 1 ? "" : "s") to Trash?"
        alert.informativeText = "The selected files will be moved to the Trash. You can recover them from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        var trashed: Set<URL> = []
        for url in urls {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashed.insert(url)
            } catch {
                print("[Seeker] Failed to trash \(url.path): \(error)")
            }
        }

        // Drop trashed files from the displayed groups; collapse groups
        // that no longer have \u2265 2 members.
        var newGroups: [DuplicateFinder.Group] = []
        for group in finder.groups {
            let remaining = group.urls.filter { !trashed.contains($0) }
            if remaining.count > 1 {
                newGroups.append(DuplicateFinder.Group(fileSize: group.fileSize, urls: remaining))
            }
        }
        finder.groups = newGroups
        toDelete.subtract(trashed)
        // Notify other panes so they refresh listings of the affected dirs.
        NotificationCenter.default.post(name: .filesDidChange, object: nil)
    }

    /// Drops a single file (trashed from the embedded explorer panel)
    /// from the displayed groups, collapsing any group that no longer
    /// has \u2265 2 members. Keeps the left list in sync with the right
    /// panel's delete action.
    private func removeFromGroups(_ url: URL) {
        let std = url.standardizedFileURL
        var newGroups: [DuplicateFinder.Group] = []
        for group in finder.groups {
            let remaining = group.urls.filter { $0.standardizedFileURL != std }
            if remaining.count > 1 {
                newGroups.append(DuplicateFinder.Group(fileSize: group.fileSize, urls: remaining))
            }
        }
        finder.groups = newGroups
        toDelete.remove(url)
        if focusedURL?.standardizedFileURL == std { focusedURL = nil }
        NotificationCenter.default.post(name: .filesDidChange, object: nil)
    }
}

private struct DuplicateGroupRow: View {
    let group: DuplicateFinder.Group
    let isExpanded: Bool
    @Binding var toDelete: Set<URL>
    @Binding var focusedURL: URL?
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
                    Text("\(group.urls.count) files \u{00B7} \(ByteCountFormatter.string(fromByteCount: group.fileSize, countStyle: .file)) each")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("Reclaim \(ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file))")
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
                    ForEach(Array(group.urls.enumerated()), id: \.element) { idx, url in
                        let isFocused = focusedURL == url
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(
                                get: { toDelete.contains(url) },
                                set: { newValue in
                                    if newValue { toDelete.insert(url) } else { toDelete.remove(url) }
                                }
                            )) {
                                EmptyView()
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.mini)

                            if idx == 0 && !toDelete.contains(url) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.yellow)
                                    .help("Suggested keep")
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if isFocused {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.accentColor)
                                    .help("Shown in explorer")
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isFocused ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(url) }
                    }
                }
                .padding(.top, 2)
            }
        }
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

