import SwiftUI
import AppKit

/// Standalone window for recursive search under a directory. Searches by
/// file name (recursive walk) or by content (Spotlight). Results can be
/// previewed, opened, revealed in Finder, or located in the main window's
/// active pane.
struct FileSearchView: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    @State private var searcher: FileSearcher
    @State private var selection: URL?
    @State private var previewURL: URL?
    @State private var showPreview = false
    @FocusState private var queryFocused: Bool

    init(root: URL) {
        _searcher = State(initialValue: FileSearcher(root: root))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            Group {
                switch searcher.status {
                case .idle:
                    idleState
                case .searching:
                    if searcher.results.isEmpty { searchingState } else { resultsList }
                case .done(let count):
                    if count == 0 { emptyState } else { resultsList }
                case .failed(let msg):
                    Text("Search failed: \(msg)")
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity,
               minHeight: 460, idealHeight: 600, maxHeight: .infinity)
        .onAppear { DispatchQueue.main.async { queryFocused = true } }
        .sheet(isPresented: $showPreview) {
            if let url = previewURL {
                VStack(spacing: 0) {
                    QuickLookPreview(url: url)
                    HStack {
                        Text(url.lastPathComponent)
                            .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search")
                    .font(.system(size: 13, weight: .semibold))
                Text(searcher.root.path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(searcher.root.path)
            }
            Spacer()
            Button { dismiss() } label: {
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

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search\u{2026}", text: $searcher.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($queryFocused)
                    .onSubmit { searcher.search() }
                if !searcher.query.isEmpty {
                    Button { searcher.query = ""; searcher.results = []; searcher.status = .idle } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Picker("", selection: $searcher.mode) {
                ForEach(FileSearcher.Mode.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: searcher.mode) { _, _ in if !searcher.query.isEmpty { searcher.search() } }

            Toggle("Hidden", isOn: $searcher.includeHidden)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .onChange(of: searcher.includeHidden) { _, _ in if !searcher.query.isEmpty { searcher.search() } }

            Button("Search") { searcher.search() }
                .disabled(searcher.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - States

    private var idleState: some View {
        centeredHint(icon: "magnifyingglass", text: searcher.mode == .contents
            ? "Search file contents with Spotlight"
            : "Search file names under this folder")
    }

    private var searchingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("Searching\u{2026}")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var emptyState: some View {
        centeredHint(icon: "questionmark.folder", text: "No matches found")
    }

    private func centeredHint(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundColor(.secondary.opacity(0.6))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        ScrollViewReader { _ in
            List(searcher.results, selection: $selection) { result in
                resultRow(result)
                    .tag(result.url)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(result) }
                    .simultaneousGesture(TapGesture(count: 1).onEnded { selection = result.url })
            }
            .listStyle(.plain)
        }
    }

    private func resultRow(_ result: FileSearcher.Result) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: SidebarRow.icon(for: result.url))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(result.relativePath)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(result.formattedSize)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 1)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if case .searching = searcher.status {
                Button("Stop") { searcher.cancel(); searcher.status = .done(count: searcher.results.count) }
            }
            Text(footerText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()
            Spacer()
            Button { if let url = selection { preview(url) } } label: {
                Label("Quick Look", systemImage: "eye").font(.system(size: 11))
            }
            .disabled(selection == nil)
            Button { if let url = selection { revealInPane(url) } } label: {
                Label("Reveal", systemImage: "scope").font(.system(size: 11))
            }
            .disabled(selection == nil)
            .help("Locate in the main window")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footerText: String {
        switch searcher.status {
        case .done(let count): return "\(count) result\(count == 1 ? "" : "s")"
        case .searching: return "Searching\u{2026}"
        default: return ""
        }
    }

    // MARK: - Actions

    private func open(_ result: FileSearcher.Result) {
        if result.isDirectory {
            revealInPane(result.url)
        } else {
            NSWorkspace.shared.open(result.url)
        }
    }

    private func preview(_ url: URL) {
        previewURL = url
        showPreview = true
    }

    /// Navigates the main window's active pane to the file's parent folder
    /// and selects it, then brings the main window forward.
    private func revealInPane(_ url: URL) {
        let explorer = appState.activeExplorer
        explorer.revealAndSelect(url)
        if let mainWin = NSApp.windows.first(where: {
            $0.identifier?.rawValue != "file-search" && $0.contentViewController != nil
        }) {
            mainWin.makeKeyAndOrderFront(nil)
        }
    }
}
