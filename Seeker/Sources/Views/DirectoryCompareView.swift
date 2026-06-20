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
            TriageExplorerPanel(
                fixedURLs: comparer.onlyInA.map(\.url),
                headerTitle: comparer.dirA.lastPathComponent,
                headerBadge: "A",
                headerBadgeColor: .blue,
                emptyMessage: "Nothing only in A",
                onDeleted: { url in handleDeleted(url) },
                onChanged: { comparer.compare() }
            )
            .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

            TriageExplorerPanel(
                fixedURLs: comparer.onlyInB.map(\.url),
                headerTitle: comparer.dirB.lastPathComponent,
                headerBadge: "B",
                headerBadgeColor: .purple,
                emptyMessage: "Nothing only in B",
                onDeleted: { url in handleDeleted(url) },
                onChanged: { comparer.compare() }
            )
            .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handleDeleted(_ url: URL) {
        // The fixed-list panels refresh from `comparer.onlyInA/onlyInB`,
        // so just drop the entry. No app-wide `.filesDidChange` broadcast
        // — that would make every main-window tab re-read its directory
        // for a file the compare window doesn't even share with them.
        comparer.remove(url)
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
