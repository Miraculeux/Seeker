import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            ColumnsSettingsTab()
                .tabItem {
                    Label("Columns", systemImage: "tablecells")
                }

            ShortcutsSettingsTab()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - General Settings

struct GeneralSettingsTab: View {
    @State private var rememberLastLocation: Bool = SettingsManager.shared.rememberLastLocation
    @State private var showFileExtensions: Bool = SettingsManager.shared.showFileExtensions
    @State private var thumbnailCacheBytes: Int64?
    @State private var isClearingCache: Bool = false
    @State private var cacheSizeRefreshTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Navigation") {
                Toggle("Remember last opened locations", isOn: $rememberLastLocation)
                    .onChange(of: rememberLastLocation) { _, newValue in
                        SettingsManager.shared.rememberLastLocation = newValue
                    }
                Text("When enabled, Seeker will restore the folder locations of both explorer panels on next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Toggle("Show file extensions", isOn: $showFileExtensions)
                    .onChange(of: showFileExtensions) { _, newValue in
                        SettingsManager.shared.showFileExtensions = newValue
                    }
                Text("When disabled, file extensions are hidden (e.g. 'photo' instead of 'photo.jpg').")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Caches") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thumbnail Cache")
                        Text(thumbnailCacheSizeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([DiskThumbnailCache.shared.directoryURL])
                    }
                    .controlSize(.small)
                    Button(isClearingCache ? "Clearing\u{2026}" : "Clear Cache") {
                        clearThumbnailCache()
                    }
                    .controlSize(.small)
                    .disabled(isClearingCache)
                }
                Text("Image, PDF and video previews shown in icon view are cached on disk so they don't have to be regenerated on every launch. Clearing this is safe; previews will be re-rendered on demand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshThumbnailCacheSize()
        }
        .onDisappear {
            cacheSizeRefreshTask?.cancel()
        }
    }

    private var thumbnailCacheSizeLabel: String {
        if let bytes = thumbnailCacheBytes {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return "Calculating\u{2026}"
    }

    private func refreshThumbnailCacheSize() async {
        let bytes = await DiskThumbnailCache.shared.currentSizeBytes()
        await MainActor.run { thumbnailCacheBytes = bytes }
    }

    private func clearThumbnailCache() {
        guard !isClearingCache else { return }
        isClearingCache = true
        cacheSizeRefreshTask?.cancel()
        cacheSizeRefreshTask = Task {
            await DiskThumbnailCache.shared.clearAndWait()
            await MainActor.run {
                ThumbnailCache.clearMemory()
            }
            await refreshThumbnailCacheSize()
            await MainActor.run { isClearingCache = false }
        }
    }
}

// MARK: - Columns Settings

struct ColumnsSettingsTab: View {
    @State private var columns: [ColumnID] = SettingsManager.shared.columnOrder
    @State private var columnVisibility: [ColumnID: Bool] = {
        var vis: [ColumnID: Bool] = [:]
        for col in ColumnID.allCases {
            vis[col] = SettingsManager.shared.isColumnVisible(col)
        }
        return vis
    }()

    var body: some View {
        Form {
            Section("List View Columns") {
                HStack {
                    Toggle("", isOn: .constant(true))
                        .labelsHidden()
                        .disabled(true)
                    Text("Name")
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(Array(columns.enumerated()), id: \.element) { index, col in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { columnVisibility[col] ?? true },
                            set: { newValue in
                                columnVisibility[col] = newValue
                                SettingsManager.shared.setColumnVisible(col, newValue)
                                NotificationCenter.default.post(name: .columnSettingsChanged, object: nil)
                            }
                        ))
                        .labelsHidden()
                        Text(col.label)
                        Spacer()
                        Button {
                            guard index > 0 else { return }
                            columns.swapAt(index, index - 1)
                            SettingsManager.shared.columnOrder = columns
                            NotificationCenter.default.post(name: .columnSettingsChanged, object: nil)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)

                        Button {
                            guard index < columns.count - 1 else { return }
                            columns.swapAt(index, index + 1)
                            SettingsManager.shared.columnOrder = columns
                            NotificationCenter.default.post(name: .columnSettingsChanged, object: nil)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == columns.count - 1)
                    }
                }

                Text("Use arrows to reorder columns. Name is always first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts Settings

struct ShortcutsSettingsTab: View {
    @State private var shortcuts: [ShortcutAction: KeyShortcut] = {
        var map: [ShortcutAction: KeyShortcut] = [:]
        for action in ShortcutAction.allCases {
            map[action] = SettingsManager.shared.shortcut(for: action)
        }
        return map
    }()
    @State private var searchText = ""
    @State private var recordingAction: ShortcutAction?
    @State private var conflictAlert = false
    @State private var conflictMessage = ""

    private var filteredActions: [ShortcutAction] {
        if searchText.isEmpty { return ShortcutAction.allCases }
        return ShortcutAction.allCases.filter {
            $0.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    private static let reservedShortcuts: [(shortcut: KeyShortcut, label: String)] = [
        (KeyShortcut(key: ",", modifiers: [.command]), "Settings"),
        (KeyShortcut(key: "q", modifiers: [.command]), "Quit"),
        (KeyShortcut(key: "h", modifiers: [.command]), "Hide App"),
        (KeyShortcut(key: "h", modifiers: [.command, .option]), "Hide Others"),
        (KeyShortcut(key: "m", modifiers: [.command]), "Minimize"),
        (KeyShortcut(key: "c", modifiers: [.command]), "Copy"),
        (KeyShortcut(key: "v", modifiers: [.command]), "Paste"),
        (KeyShortcut(key: "x", modifiers: [.command]), "Cut"),
        (KeyShortcut(key: "a", modifiers: [.command]), "Select All"),
        (KeyShortcut(key: "z", modifiers: [.command]), "Undo"),
        (KeyShortcut(key: "z", modifiers: [.command, .shift]), "Redo"),
        (KeyShortcut(key: "n", modifiers: [.command]), "New Window"),
        (KeyShortcut(key: "f", modifiers: [.command]), "Find"),
        (KeyShortcut(key: "p", modifiers: [.command]), "Print"),
        (KeyShortcut(key: "r", modifiers: [.command]), "Refresh"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search shortcuts…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Shortcuts list
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ShortcutCategory.allCases, id: \.self) { category in
                        let actions = filteredActions.filter { $0.category == category }
                        if !actions.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.rawValue.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .tracking(0.5)
                                    .padding(.horizontal, 4)
                                    .padding(.bottom, 4)

                                ForEach(actions) { action in
                                    ShortcutRow(
                                        action: action,
                                        shortcut: shortcuts[action] ?? action.defaultShortcut,
                                        isRecording: recordingAction == action,
                                        onStartRecording: { recordingAction = action },
                                        onRecord: { newShortcut in
                                            // Check for reserved system/menu shortcuts
                                            if let reserved = Self.reservedShortcuts.first(where: { $0.shortcut == newShortcut }) {
                                                recordingAction = nil
                                                ShortcutRecorderNSView.isRecordingShortcut = false
                                                ShortcutRecorderNSView.activeRecorder = nil
                                                conflictMessage = "\"\(newShortcut.displayString)\" is reserved by the system for \"\(reserved.label)\". Choose a different shortcut."
                                                conflictAlert = true
                                                return
                                            }
                                            // Check for conflicts with other configured shortcuts
                                            if let conflict = shortcuts.first(where: { $0.key != action && $0.value == newShortcut }) {
                                                recordingAction = nil
                                                ShortcutRecorderNSView.isRecordingShortcut = false
                                                ShortcutRecorderNSView.activeRecorder = nil
                                                conflictMessage = "\"\(newShortcut.displayString)\" is already used by \"\(conflict.key.label)\". Choose a different shortcut."
                                                conflictAlert = true
                                                return
                                            }
                                            shortcuts[action] = newShortcut
                                            SettingsManager.shared.setShortcut(newShortcut, for: action)
                                            recordingAction = nil
                                            ShortcutRecorderNSView.isRecordingShortcut = false
                                            ShortcutRecorderNSView.activeRecorder = nil
                                        },
                                        onCancel: {
                                            recordingAction = nil
                                            ShortcutRecorderNSView.isRecordingShortcut = false
                                            ShortcutRecorderNSView.activeRecorder = nil
                                        },
                                        onReset: {
                                            shortcuts[action] = action.defaultShortcut
                                            SettingsManager.shared.resetShortcut(for: action)
                                            recordingAction = nil
                                            ShortcutRecorderNSView.isRecordingShortcut = false
                                            ShortcutRecorderNSView.activeRecorder = nil
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider()

            // Footer
            HStack {
                Button("Reset All to Defaults") {
                    SettingsManager.shared.resetAllShortcuts()
                    for action in ShortcutAction.allCases {
                        shortcuts[action] = action.defaultShortcut
                    }
                    recordingAction = nil
                }
                .font(.system(size: 11))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .alert("Shortcut Conflict", isPresented: $conflictAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(conflictMessage)
        }
    }
}

// MARK: - Shortcut Row

struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcut: KeyShortcut
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onRecord: (KeyShortcut) -> Void
    let onCancel: () -> Void
    let onReset: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(action.label)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRecording {
                ShortcutRecorderField(onRecord: onRecord, onCancel: onCancel)
                    .frame(width: 160)
            } else {
                Button(action: onStartRecording) {
                    Text(shortcut.displayString)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .frame(minWidth: 60)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }

                if shortcut != action.defaultShortcut {
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}

// MARK: - Shortcut Recorder

struct ShortcutRecorderField: NSViewRepresentable {
    let onRecord: (KeyShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onCancel = onCancel
    }
}

class ShortcutRecorderNSView: NSView {
    static var isRecordingShortcut = false
    static weak var activeRecorder: ShortcutRecorderNSView?
    var onRecord: ((KeyShortcut) -> Void)?
    var onCancel: (() -> Void)?

    private let label: NSTextField = {
        let tf = NSTextField(labelWithString: "Type shortcut…")
        tf.font = .systemFont(ofSize: 11, weight: .medium)
        tf.textColor = .secondaryLabelColor
        tf.alignment = .center
        return tf
    }()

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        ShortcutRecorderNSView.isRecordingShortcut = true
        ShortcutRecorderNSView.activeRecorder = self
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        ShortcutRecorderNSView.isRecordingShortcut = false
        ShortcutRecorderNSView.activeRecorder = nil
        return super.resignFirstResponder()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 24)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require at least Cmd or Ctrl for non-special keys
        let key = keyString(from: event)
        guard !key.isEmpty else { return }

        var mods: Set<KeyShortcut.KeyModifier> = []
        if modifiers.contains(.command) { mods.insert(.command) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.control) { mods.insert(.control) }

        let shortcut = KeyShortcut(key: key, modifiers: mods)
        onRecord?(shortcut)
    }

    private func keyString(from event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Return: return "⏎"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "PgUp"
        case kVK_PageDown: return "PgDn"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        default:
            return event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }
}
