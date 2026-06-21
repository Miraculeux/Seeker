import SwiftUI
import AppKit

/// Standalone window that syncs two folders. Pick a direction (mirror,
/// one-way update, or two-way), review the planned actions (each can be
/// toggled off), then apply. Matching is by relative path; "changed" is
/// detected by size + modification time.
struct FolderSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var syncer: FolderSyncer

    init(rootA: URL, rootB: URL) {
        _syncer = State(initialValue: FolderSyncer(rootA: rootA, rootB: rootB))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            Group {
                switch syncer.status {
                case .idle, .analyzing:
                    centered { ProgressView(); Text("Analyzing\u{2026}").font(.system(size: 11)).foregroundColor(.secondary) }
                case .ready, .syncing, .finished, .cancelled:
                    if syncer.actions.isEmpty {
                        centered {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 32)).foregroundColor(.green.opacity(0.7))
                            Text("Folders are already in sync").font(.system(size: 12, weight: .medium))
                        }
                    } else {
                        actionList
                    }
                case .failed(let msg):
                    centered { Text("Sync failed: \(msg)").foregroundColor(.red) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 660, idealWidth: 820, maxWidth: .infinity,
               minHeight: 480, idealHeight: 620, maxHeight: .infinity)
        .onAppear { syncer.analyze() }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Folders")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    badge("A", .blue)
                    Text(syncer.rootA.lastPathComponent).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).help(syncer.rootA.path)
                    Text("\u{2194}").font(.system(size: 10)).foregroundColor(.secondary)
                    badge("B", .purple)
                    Text(syncer.rootB.lastPathComponent).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).help(syncer.rootB.path)
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }

    private func badge(_ letter: String, _ color: Color) -> some View {
        Text(letter)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(color.opacity(0.85)))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(
                get: { syncer.direction },
                set: { syncer.direction = $0; syncer.analyze() }
            )) {
                ForEach(FolderSyncer.Direction.allCases) { d in Text(d.title).tag(d) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Toggle("Hidden files", isOn: Binding(
                get: { syncer.includeHidden },
                set: { syncer.includeHidden = $0; syncer.analyze() }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))

            Spacer()

            Text(directionHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var directionHint: String {
        switch syncer.direction {
        case .mirror: return "B becomes an exact copy of A (extras in B are trashed)"
        case .update: return "New & newer files copied A \u{2192} B; nothing deleted"
        case .twoWay: return "Newer file wins on each side; nothing deleted"
        }
    }

    // MARK: - Action list

    private var actionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach($syncer.actions) { $action in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $action.enabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(isBusy)
                        Image(systemName: action.kind.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(color(for: action.kind))
                            .frame(width: 16)
                        Text(action.relativePath)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(action.enabled ? .primary : .secondary)
                        Spacer()
                        Text(action.kind == .deleteB ? "" : ByteCountFormatter.string(fromByteCount: action.size, countStyle: .file))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                        Text(action.kind.label)
                            .font(.system(size: 9))
                            .foregroundColor(color(for: action.kind))
                            .frame(width: 78, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func color(for kind: FolderSyncer.Action.Kind) -> Color {
        switch kind {
        case .copyToB: return .blue
        case .copyToA: return .purple
        case .deleteB: return .red
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { syncer.analyze() } label: {
                Label("Re-analyze", systemImage: "arrow.clockwise").font(.system(size: 11))
            }
            .disabled(isBusy)

            if case .syncing = syncer.status {
                Button {
                    syncer.togglePause()
                } label: {
                    Label(syncer.isPaused ? "Resume" : "Pause",
                          systemImage: syncer.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11))
                }
                Button("Stop") { syncer.cancel() }
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(syncButtonTitle) { syncer.apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSync)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var isBusy: Bool {
        if case .syncing = syncer.status { return true }
        if case .analyzing = syncer.status { return true }
        return false
    }

    private var canSync: Bool {
        guard !isBusy else { return false }
        return !syncer.enabledActions.isEmpty
    }

    private var syncButtonTitle: String {
        if case .syncing = syncer.status { return "Syncing\u{2026}" }
        return "Sync"
    }

    private var statusText: String {
        switch syncer.status {
        case .ready:
            let copyB = syncer.actions.filter { $0.kind == .copyToB }.count
            let copyA = syncer.actions.filter { $0.kind == .copyToA }.count
            let del = syncer.actions.filter { $0.kind == .deleteB }.count
            var parts: [String] = []
            if copyB > 0 { parts.append("\(copyB) \u{2192} B") }
            if copyA > 0 { parts.append("\(copyA) \u{2192} A") }
            if del > 0 { parts.append("\(del) delete") }
            let enabled = syncer.enabledActions.count
            return parts.isEmpty ? "" : parts.joined(separator: " \u{00B7} ") + " \u{00B7} \(enabled) selected"
        case .syncing(let done, let total):
            return "\(done) / \(total)"
        case .finished(let applied, let failed):
            return failed > 0 ? "\(applied) done, \(failed) failed" : "\(applied) synced"
        case .cancelled:
            return "Cancelled"
        default:
            return ""
        }
    }
}
