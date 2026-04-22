import SwiftUI
import AppKit

struct PaneView: View {
    var pane: PaneState
    @Environment(AppState.self) var appState
    let side: AppState.PaneSide
    @FocusState private var isFilterFocused: Bool

    var isActive: Bool {
        appState.activePane == side
    }

    private var viewModeBinding: Binding<FileExplorerViewModel.ViewMode> {
        Binding(
            get: { pane.activeTab.viewMode },
            set: { pane.activeTab.viewMode = $0 }
        )
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { pane.activeTab.searchText },
            set: { pane.activeTab.searchText = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            paneToolbar
            fileArea
            paneStatusBar
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isActive
                        ? Color.accentColor.opacity(0.5)
                        : Color.primary.opacity(0.06),
                    lineWidth: isActive ? 1.5 : 0.5
                )
        )
        .shadow(color: .black.opacity(isActive ? 0.08 : 0.03), radius: isActive ? 8 : 3, y: 2)
        .padding(4)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        updatePaneFrame(geo)
                    }
                    .onChange(of: geo.frame(in: .global)) { _, _ in
                        updatePaneFrame(geo)
                    }
            }
        )
    }

    private func updatePaneFrame(_ geo: GeometryProxy) {
        let frame = geo.frame(in: .global)
        if side == .left {
            appState.leftPaneFrame = frame
        } else {
            appState.rightPaneFrame = frame
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        ModernTabItem(
                            title: tab.tabTitle,
                            isSelected: index == pane.activeTabIndex,
                            isActivePane: isActive,
                            onSelect: {
                                pane.selectTab(index)
                                appState.activePane = side
                            },
                            onClose: pane.tabs.count > 1 ? {
                                pane.closeTab(at: index)
                            } : nil
                        )
                    }
                }
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 4)

            Button {
                pane.addTab()
                appState.activePane = side
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.borderless)
            .padding(.trailing, 8)
        }
        .frame(height: 34)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Pane Toolbar

    private var paneToolbar: some View {
        HStack(spacing: 5) {
            // Navigation pills
            HStack(spacing: 2) {
                NavButton(icon: "chevron.left", action: pane.activeTab.goBack, disabled: !pane.activeTab.canGoBack)
                NavButton(icon: "chevron.right", action: pane.activeTab.goForward, disabled: !pane.activeTab.canGoForward)
                NavButton(icon: "chevron.up", action: pane.activeTab.goUp, disabled: !pane.activeTab.canGoUp)
                if appState.showDualPane {
                    NavButton(icon: "arrow.left.arrow.right", action: {
                        let otherPane = side == .left ? appState.rightPane : appState.leftPane
                        pane.activeTab.navigateTo(otherPane.activeTab.currentURL)
                    }, disabled: false)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Path breadcrumb
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    let components = pane.activeTab.pathComponents
                    ForEach(0..<components.count, id: \.self) { index in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.35))
                                .padding(.horizontal, 1)
                        }
                        BreadcrumbButton(
                            label: components[index].0,
                            isLast: index == components.count - 1
                        ) {
                            pane.activeTab.navigateTo(components[index].1)
                        }
                    }
                }
            }

            // View mode picker
            Picker("", selection: viewModeBinding) {
                Image(systemName: "list.bullet").tag(FileExplorerViewModel.ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(FileExplorerViewModel.ViewMode.icons)
                Image(systemName: "rectangle.split.3x1").tag(FileExplorerViewModel.ViewMode.columns)
            }
            .pickerStyle(.segmented)
            .frame(width: 96)
            .controlSize(.small)

            // Icon-zoom slider, only shown in icon view. Bound directly to
            // `iconSize`; the property's didSet handles persistence and
            // cross-pane sync, and clamping happens on assignment so the
            // slider's range is just a UX hint, not the source of truth.
            if pane.activeTab.viewMode == .icons {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                    Slider(
                        value: Binding(
                            get: { Double(pane.activeTab.iconSize) },
                            set: { pane.activeTab.setIconSize(CGFloat($0)) }
                        ),
                        in: Double(SettingsManager.iconSizeMin)...Double(SettingsManager.iconSizeMax)
                    )
                    .controlSize(.mini)
                    .frame(width: 70)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .help("Icon size (⌘+ / ⌘-)")
            }

            // Refresh button
            NavButton(icon: "arrow.clockwise", action: { pane.activeTab.loadFiles() }, disabled: false)

            // Show hidden files
            NavButton(icon: pane.activeTab.showHiddenFiles ? "eye" : "eye.slash", action: {
                pane.activeTab.showHiddenFiles.toggle()
                pane.activeTab.loadFiles()
            }, disabled: false)

            // Filter field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
                TextField("Filter", text: searchTextBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($isFilterFocused)
                    .onChange(of: pane.activeTab.searchText) { pane.activeTab.refilter() }
                if !pane.activeTab.searchText.isEmpty {
                    Button {
                        pane.activeTab.searchText = ""
                        pane.activeTab.refilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: 140)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.015))
    }

    // MARK: - File Area

    private var fileArea: some View {
        FileContentView(viewModel: pane.activeTab, side: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status Bar

    private var paneStatusBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
                Text("\(pane.activeTab.files.count) items")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }

            if let sel = pane.activeTab.selectedFile {
                Text("·").foregroundColor(.secondary.opacity(0.3))
                Text(sel.name)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !sel.isDirectory {
                    Text(sel.formattedSize)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }

            Spacer()

            if let space = freeSpace() {
                Text(space)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.02))
    }

    private func freeSpace() -> String? {
        return FreeSpaceCache.shared.formatted(for: pane.activeTab.currentURL)
    }
}

/// Caches `volumeAvailableCapacityForImportantUsage` results per volume.
///
/// `volumeAvailableCapacityForImportantUsage` is documented as expensive
/// (it queries the volume daemon). The status bar reads it from `body`,
/// which fires on every selection / hover / focus change — without caching
/// this is one of the hottest items in Instruments. We refresh on volume
/// mount/unmount notifications and at most every 5 seconds otherwise.
@MainActor
final class FreeSpaceCache {
    static let shared = FreeSpaceCache()

    private struct Entry {
        var formatted: String
        var fetchedAt: Date
    }
    private var byVolume: [URL: Entry] = [:]
    private let ttl: TimeInterval = 5.0

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.byVolume.removeAll() }
            }
        }
    }

    func formatted(for url: URL) -> String? {
        let volumeURL = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? url
        if let entry = byVolume[volumeURL],
           Date().timeIntervalSince(entry.fetchedAt) < ttl {
            return entry.formatted
        }
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        let str = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " free"
        byVolume[volumeURL] = Entry(formatted: str, fetchedAt: Date())
        return str
    }
}

// MARK: - Navigation Button

struct NavButton: View {
    let icon: String
    let action: () -> Void
    let disabled: Bool
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(disabled ? .secondary.opacity(0.25) : (hovering ? .primary : .secondary))
                .frame(width: 24, height: 22)
                .background(hovering && !disabled ? Color.primary.opacity(0.06) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

// MARK: - Breadcrumb Button

struct BreadcrumbButton: View {
    let label: String
    let isLast: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isLast ? .medium : .regular))
                .foregroundColor(isLast ? .primary : .secondary.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
    }
}

// MARK: - Modern Tab Item

struct ModernTabItem: View {
    let title: String
    let isSelected: Bool
    let isActivePane: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : .secondary.opacity(0.7))

            if let onClose = onClose, (hovering || isSelected) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.5))
                        .frame(width: 14, height: 14)
                        .background(hovering ? Color.primary.opacity(0.08) : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                } else {
                    Color.clear
                }
            }
        )
        .overlay(
            Group {
                if isSelected && isActivePane {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 0.5)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.1), value: hovering)
    }
}

// MARK: - Share Button

struct ShareButton: View {
    @Bindable var viewModel: FileExplorerViewModel
    @State private var hovering = false

    var body: some View {
        Button {
            let urls = viewModel.effectiveSelection.map(\.url)
            guard !urls.isEmpty else { return }
            let picker = NSSharingServicePicker(items: urls)
            if let window = NSApp.keyWindow, let contentView = window.contentView {
                let point = contentView.convert(NSEvent.mouseLocation, from: nil)
                picker.show(relativeTo: NSRect(origin: point, size: .zero), of: contentView, preferredEdge: .minY)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hasSelection ? (hovering ? .primary : .secondary) : .secondary.opacity(0.25))
                .frame(width: 24, height: 22)
                .background(hovering && hasSelection ? Color.primary.opacity(0.06) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.borderless)
        .disabled(!hasSelection)
        .onHover { hovering = $0 }
        .help("Share")
    }

    private var hasSelection: Bool {
        viewModel.selectedFile != nil || !viewModel.selectedFileIDs.isEmpty
    }
}
