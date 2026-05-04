import SwiftUI
import AppKit

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

    let rootURL: URL

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .frame(width: 720, height: 540)
        .onAppear {
            finder.scan(root: rootURL)
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
                Text(rootURL.path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        ScrollView {
            LazyVStack(spacing: 4) {
                summaryBanner
                ForEach(finder.groups) { group in
                    DuplicateGroupRow(
                        group: group,
                        isExpanded: expanded.contains(group.id),
                        toDelete: $toDelete,
                        onToggleExpand: {
                            if expanded.contains(group.id) {
                                expanded.remove(group.id)
                            } else {
                                expanded.insert(group.id)
                            }
                        },
                        onReveal: { url in
                            // Surface the file in the main window's active
                            // pane while leaving this duplicate window open
                            // so the user can keep triaging. Reuse the
                            // active tab if it's already viewing the
                            // parent dir; otherwise open a new tab there
                            // so we don't blow away their navigation.
                            let pane = appState.activePaneState
                            let parent = url.deletingLastPathComponent().standardizedFileURL
                            if pane.activeTab.currentURL.standardizedFileURL != parent {
                                pane.addTab(url: parent)
                            }
                            pane.activeTab.revealAndSelect(url)
                            // Bring the main window forward so the user
                            // actually sees the highlighted file.
                            if let mainWin = NSApp.windows.first(where: {
                                $0.identifier?.rawValue != "duplicate-finder"
                                    && $0.contentViewController != nil
                            }) {
                                mainWin.makeKeyAndOrderFront(nil)
                            }
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
}

private struct DuplicateGroupRow: View {
    let group: DuplicateFinder.Group
    let isExpanded: Bool
    @Binding var toDelete: Set<URL>
    let onToggleExpand: () -> Void
    let onReveal: (URL) -> Void

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
                            Button {
                                onReveal(url)
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .help("Open in new tab")
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}
