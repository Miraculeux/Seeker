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
        }
        .frame(minWidth: 940, idealWidth: 1100, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .onAppear { comparer.compare() }
        // Re-compare when files change elsewhere (e.g. after a Sync from
        // this window, or copy/move/rename in the side panels).
        .onReceive(NotificationCenter.default.publisher(for: .filesDidChange)) { _ in
            comparer.compare()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1.fill")
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
            sideBadge("A", color: .blue)
            Text(comparer.dirA.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(comparer.dirA.path)
            Text("\u{2194}")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            sideBadge("B", color: .purple)
            Text(comparer.dirB.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(comparer.dirB.path)

            Spacer(minLength: 12)

            Text(summary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .fixedSize()

            Button {
                comparer.compare()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rescan")

            Toggle("Recursive", isOn: Binding(
                get: { comparer.recursive },
                set: { comparer.recursive = $0; comparer.compare() }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .help("Compare entire folder trees by relative path")

            Button {
                appState.folderSyncRoots = [comparer.dirA, comparer.dirB]
            } label: {
                Label("Sync\u{2026}", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
            }
            .help("Sync these two folders\u{2026}")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
            TriageExplorerPanel(
                fixedURLs: comparer.onlyInA.map(\.url),
                headerTitle: comparer.dirA.lastPathComponent,
                headerBadge: "A",
                headerBadgeColor: .blue,
                emptyMessage: comparer.recursive ? "Every file in A exists in B" : "Nothing only in A",
                subtitles: comparer.recursive ? subtitleMap(comparer.onlyInA) : nil,
                onDeleted: { url in handleDeleted(url) },
                onChanged: { comparer.compare() }
            )
            .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

            TriageExplorerPanel(
                fixedURLs: comparer.onlyInB.map(\.url),
                headerTitle: comparer.dirB.lastPathComponent,
                headerBadge: "B",
                headerBadgeColor: .purple,
                emptyMessage: comparer.recursive ? "Every file in B exists in A" : "Nothing only in B",
                subtitles: comparer.recursive ? subtitleMap(comparer.onlyInB) : nil,
                onDeleted: { url in handleDeleted(url) },
                onChanged: { comparer.compare() }
            )
            .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Maps each entry's URL to its relative subpath for the panel's
    /// secondary row label (recursive mode).
    private func subtitleMap(_ entries: [DirectoryComparer.Entry]) -> [URL: String] {
        Dictionary(entries.map { ($0.url, $0.relativePath) }, uniquingKeysWith: { a, _ in a })
    }

    private func handleDeleted(_ url: URL) {
        // The fixed-list panels refresh from `comparer.onlyInA/onlyInB`,
        // so just drop the entry. No app-wide `.filesDidChange` broadcast
        // — that would make every main-window tab re-read its directory
        // for a file the compare window doesn't even share with them.
        comparer.remove(url)
    }

    // MARK: - Summary

    private var summary: String {
        "\(comparer.onlyInA.count) only in A \u{00B7} \(comparer.onlyInB.count) only in B"
    }
}
