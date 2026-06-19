import SwiftUI
import AppKit

/// Window that compares two folders by file name (case-insensitive) and
/// shows the differences. The left side is split top/bottom: the top
/// lists entries present only in folder A, the bottom lists entries
/// present only in folder B. Selecting any row locates and highlights it
/// in the embedded explorer on the right, where it can be previewed,
/// opened, or moved to the Trash.
struct DirectoryCompareView: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    @State private var comparer: DirectoryComparer
    /// The entry the user clicked on the left; drives the explorer on
    /// the right to navigate to and highlight it.
    @State private var focusedURL: URL?

    init(dirA: URL, dirB: URL) {
        _comparer = State(initialValue: DirectoryComparer(dirA: dirA, dirB: dirB))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch comparer.status {
                case .idle, .comparing:
                    progressState
                case .done:
                    resultsState
                case .failed(let msg):
                    Text("Compare failed: \(msg)")
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
        .onAppear { comparer.compare() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1.fill")
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare Folders")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    sideBadge("A", color: .blue)
                    Text(comparer.dirA.lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(comparer.dirA.path)
                    Text("\u{2194}")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    sideBadge("B", color: .purple)
                    Text(comparer.dirB.lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(comparer.dirB.path)
                }
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

    private func sideBadge(_ letter: String, color: Color) -> some View {
        Text(letter)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(color.opacity(0.85)))
    }

    // MARK: - States

    private var progressState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Comparing folders\u{2026}")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var resultsState: some View {
        HSplitView {
            VSplitView {
                differenceList(
                    title: "Only in A",
                    badge: "A",
                    badgeColor: .blue,
                    folderName: comparer.dirA.lastPathComponent,
                    entries: comparer.onlyInA
                )
                .frame(minHeight: 140, maxHeight: .infinity)

                differenceList(
                    title: "Only in B",
                    badge: "B",
                    badgeColor: .purple,
                    folderName: comparer.dirB.lastPathComponent,
                    entries: comparer.onlyInB
                )
                .frame(minHeight: 140, maxHeight: .infinity)
            }
            .frame(minWidth: 340, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            TriageExplorerPanel(
                targetURL: focusedURL,
                onDeleted: { url in
                    comparer.remove(url)
                    if focusedURL?.standardizedFileURL == url.standardizedFileURL {
                        focusedURL = nil
                    }
                    NotificationCenter.default.post(name: .filesDidChange, object: nil)
                }
            )
            .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func differenceList(
        title: String,
        badge: String,
        badgeColor: Color,
        folderName: String,
        entries: [DirectoryComparer.Entry]
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                sideBadge(badge, color: badgeColor)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(folderName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))

            Divider()

            if entries.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.green.opacity(0.6))
                    Text("Nothing unique here")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func entryRow(_ entry: DirectoryComparer.Entry) -> some View {
        let isFocused = focusedURL?.standardizedFileURL == entry.url.standardizedFileURL
        return HStack(spacing: 7) {
            Image(nsImage: SidebarRow.icon(for: entry.url))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(entry.isDirectory ? "" : entry.formattedSize)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .monospacedDigit()
            if entry.isDirectory {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isFocused ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { focusedURL = entry.url }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                comparer.compare()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            Spacer()
            Text(summary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        "\(comparer.onlyInA.count) only in A \u{00B7} \(comparer.onlyInB.count) only in B"
    }
}
