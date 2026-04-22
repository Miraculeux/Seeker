import Foundation
import Carbon.HIToolbox

enum ColumnID: String, CaseIterable, Identifiable {
    case size = "size"
    case modified = "modified"
    case kind = "kind"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .size: return "Size"
        case .modified: return "Date Modified"
        case .kind: return "Kind"
        }
    }
}

// MARK: - Keyboard Shortcut Configuration

enum ShortcutAction: String, CaseIterable, Identifiable {
    // File operations
    case openFile = "openFile"
    case newFolder = "newFolder"
    case newFile = "newFile"
    case duplicate = "duplicate"
    case moveToTrash = "moveToTrash"
    case rename = "rename"
    case copyToOtherPane = "copyToOtherPane"
    case moveToOtherPane = "moveToOtherPane"

    // Navigation
    case goBack = "goBack"
    case goForward = "goForward"
    case enclosingFolder = "enclosingFolder"
    case goHome = "goHome"
    case goDesktop = "goDesktop"
    case goDownloads = "goDownloads"
    case goToFolder = "goToFolder"

    // View
    case toggleFavorites = "toggleFavorites"
    case toggleDualPane = "toggleDualPane"
    case listView = "listView"
    case iconView = "iconView"
    case columnView = "columnView"
    case toggleHiddenFiles = "toggleHiddenFiles"

    // Tabs
    case newTab = "newTab"
    case closeTab = "closeTab"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openFile: return "Open File"
        case .newFolder: return "New Folder"
        case .newFile: return "New File"
        case .duplicate: return "Duplicate"
        case .moveToTrash: return "Move to Trash"
        case .rename: return "Rename"
        case .copyToOtherPane: return "Copy to Other Pane"
        case .moveToOtherPane: return "Move to Other Pane"
        case .goBack: return "Back"
        case .goForward: return "Forward"
        case .enclosingFolder: return "Enclosing Folder"
        case .goHome: return "Home"
        case .goDesktop: return "Desktop"
        case .goDownloads: return "Downloads"
        case .goToFolder: return "Go to Folder…"
        case .toggleFavorites: return "Toggle Favorites"
        case .toggleDualPane: return "Toggle Dual Pane"
        case .listView: return "List View"
        case .iconView: return "Icon View"
        case .columnView: return "Column View"
        case .toggleHiddenFiles: return "Show/Hide Hidden Files"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        }
    }

    var category: ShortcutCategory {
        switch self {
        case .openFile, .newFolder, .newFile, .duplicate, .moveToTrash, .rename, .copyToOtherPane, .moveToOtherPane:
            return .fileOperations
        case .goBack, .goForward, .enclosingFolder, .goHome, .goDesktop, .goDownloads, .goToFolder:
            return .navigation
        case .toggleFavorites, .toggleDualPane, .listView, .iconView, .columnView, .toggleHiddenFiles:
            return .view
        case .newTab, .closeTab:
            return .tabs
        }
    }

    var defaultShortcut: KeyShortcut {
        switch self {
        case .openFile: return KeyShortcut(key: "o", modifiers: [.command])
        case .newFolder: return KeyShortcut(key: "n", modifiers: [.command, .shift])
        case .newFile: return KeyShortcut(key: "n", modifiers: [.command, .option])
        case .duplicate: return KeyShortcut(key: "d", modifiers: [.command])
        case .moveToTrash: return KeyShortcut(key: "⌫", modifiers: [.command])
        case .rename: return KeyShortcut(key: "⏎", modifiers: [])
        case .copyToOtherPane: return KeyShortcut(key: "c", modifiers: [.command, .shift])
        case .moveToOtherPane: return KeyShortcut(key: "m", modifiers: [.command, .shift])
        case .goBack: return KeyShortcut(key: "[", modifiers: [.command])
        case .goForward: return KeyShortcut(key: "]", modifiers: [.command])
        case .enclosingFolder: return KeyShortcut(key: "↑", modifiers: [.command])
        case .goHome: return KeyShortcut(key: "h", modifiers: [.command, .shift])
        case .goDesktop: return KeyShortcut(key: "d", modifiers: [.command, .shift])
        case .goDownloads: return KeyShortcut(key: "l", modifiers: [.command, .shift])
        case .goToFolder: return KeyShortcut(key: "g", modifiers: [.command, .shift])
        case .toggleFavorites: return KeyShortcut(key: "b", modifiers: [.command])
        case .toggleDualPane: return KeyShortcut(key: "u", modifiers: [.command])
        case .listView: return KeyShortcut(key: "1", modifiers: [.command])
        case .iconView: return KeyShortcut(key: "2", modifiers: [.command])
        case .columnView: return KeyShortcut(key: "3", modifiers: [.command])
        case .toggleHiddenFiles: return KeyShortcut(key: ".", modifiers: [.command, .shift])
        case .newTab: return KeyShortcut(key: "t", modifiers: [.command])
        case .closeTab: return KeyShortcut(key: "w", modifiers: [.command])
        }
    }
}

enum ShortcutCategory: String, CaseIterable {
    case fileOperations = "File Operations"
    case navigation = "Navigation"
    case view = "View"
    case tabs = "Tabs"
}

struct KeyShortcut: Codable, Equatable {
    var key: String
    var modifiers: Set<KeyModifier>

    enum KeyModifier: String, Codable, CaseIterable {
        case command
        case shift
        case option
        case control
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyDisplayString)
        return parts.joined()
    }

    private var keyDisplayString: String {
        switch key.lowercased() {
        case "⌫", "delete": return "⌫"
        case "⏎", "return": return "⏎"
        case "↑", "uparrow": return "↑"
        case "↓", "downarrow": return "↓"
        case "←", "leftarrow": return "←"
        case "→", "rightarrow": return "→"
        case " ", "space": return "Space"
        case "⇥", "tab": return "⇥"
        case "⎋", "escape": return "⎋"
        default: return key.uppercased()
        }
    }
}

@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let rememberLastLocation = "rememberLastLocation"
        static let leftPanePath = "lastLeftPanePath"
        static let rightPanePath = "lastRightPanePath"
        static let showFavorites = "showFavorites"
        static let showInfoPanel = "showInfoPanel"
        static let showDualPane = "showDualPane"
        static let showSizeColumn = "showSizeColumn"
        static let showModifiedColumn = "showModifiedColumn"
        static let showKindColumn = "showKindColumn"
        static let columnOrder = "columnOrder"
        static let showFileExtensions = "showFileExtensions"
        static let leftPaneViewMode = "lastLeftPaneViewMode"
        static let rightPaneViewMode = "lastRightPaneViewMode"
    }

    var rememberLastLocation: Bool {
        get { defaults.bool(forKey: Keys.rememberLastLocation) }
        set { defaults.set(newValue, forKey: Keys.rememberLastLocation) }
    }

    var showFileExtensions: Bool {
        get { defaults.object(forKey: Keys.showFileExtensions) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showFileExtensions) }
    }

    var showFavorites: Bool {
        get { defaults.object(forKey: Keys.showFavorites) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showFavorites) }
    }

    var showInfoPanel: Bool {
        get { defaults.bool(forKey: Keys.showInfoPanel) }
        set { defaults.set(newValue, forKey: Keys.showInfoPanel) }
    }

    var showDualPane: Bool {
        get { defaults.object(forKey: Keys.showDualPane) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showDualPane) }
    }

    var showSizeColumn: Bool {
        get { defaults.object(forKey: Keys.showSizeColumn) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.showSizeColumn)
            Self._cachedVisibleColumns = nil
        }
    }

    var showModifiedColumn: Bool {
        get { defaults.object(forKey: Keys.showModifiedColumn) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.showModifiedColumn)
            Self._cachedVisibleColumns = nil
        }
    }

    var showKindColumn: Bool {
        get { defaults.object(forKey: Keys.showKindColumn) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.showKindColumn)
            Self._cachedVisibleColumns = nil
        }
    }

    var columnOrder: [ColumnID] {
        get {
            guard let raw = defaults.stringArray(forKey: Keys.columnOrder) else {
                return ColumnID.allCases
            }
            let parsed = raw.compactMap { ColumnID(rawValue: $0) }
            // Ensure all columns are present
            let missing = ColumnID.allCases.filter { !parsed.contains($0) }
            return parsed + missing
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: Keys.columnOrder)
            Self._cachedVisibleColumns = nil
        }
    }

    func isColumnVisible(_ column: ColumnID) -> Bool {
        switch column {
        case .size: return showSizeColumn
        case .modified: return showModifiedColumn
        case .kind: return showKindColumn
        }
    }

    func setColumnVisible(_ column: ColumnID, _ visible: Bool) {
        switch column {
        case .size: showSizeColumn = visible
        case .modified: showModifiedColumn = visible
        case .kind: showKindColumn = visible
        }
    }

    /// Cached `visibleColumnsOrdered`. The unfiltered/uncached version reads
    /// `UserDefaults` four times (once per column setting + once for the
    /// order array) and reallocates two arrays. SwiftUI calls this from row
    /// `body` closures, so caching it removes O(rows × columns) UserDefaults
    /// reads per redraw. Invalidated by the setters above.
    private static var _cachedVisibleColumns: [ColumnID]?
    var visibleColumnsOrdered: [ColumnID] {
        if let cached = Self._cachedVisibleColumns { return cached }
        let computed = columnOrder.filter { isColumnVisible($0) }
        Self._cachedVisibleColumns = computed
        return computed
    }

    var lastLeftPanePath: String? {
        get { defaults.string(forKey: Keys.leftPanePath) }
        set { defaults.set(newValue, forKey: Keys.leftPanePath) }
    }

    var lastRightPanePath: String? {
        get { defaults.string(forKey: Keys.rightPanePath) }
        set { defaults.set(newValue, forKey: Keys.rightPanePath) }
    }

    var lastLeftPaneViewMode: String? {
        get { defaults.string(forKey: Keys.leftPaneViewMode) }
        set { defaults.set(newValue, forKey: Keys.leftPaneViewMode) }
    }

    var lastRightPaneViewMode: String? {
        get { defaults.string(forKey: Keys.rightPaneViewMode) }
        set { defaults.set(newValue, forKey: Keys.rightPaneViewMode) }
    }

    func saveLocations(left: URL, right: URL, leftViewMode: String, rightViewMode: String) {
        lastLeftPanePath = left.path
        lastRightPanePath = right.path
        lastLeftPaneViewMode = leftViewMode
        lastRightPaneViewMode = rightViewMode
        defaults.synchronize()
    }

    func savedLeftURL() -> URL? {
        guard rememberLastLocation,
              let path = lastLeftPanePath else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func savedRightURL() -> URL? {
        guard rememberLastLocation,
              let path = lastRightPanePath else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Keyboard Shortcuts

    private var shortcutCache: [ShortcutAction: KeyShortcut] = [:]

    func shortcut(for action: ShortcutAction) -> KeyShortcut {
        if let cached = shortcutCache[action] { return cached }
        if let data = defaults.data(forKey: "shortcut_\(action.rawValue)"),
           let decoded = try? JSONDecoder().decode(KeyShortcut.self, from: data) {
            shortcutCache[action] = decoded
            return decoded
        }
        return action.defaultShortcut
    }

    func setShortcut(_ shortcut: KeyShortcut, for action: ShortcutAction) {
        shortcutCache[action] = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: "shortcut_\(action.rawValue)")
        }
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    func resetShortcut(for action: ShortcutAction) {
        shortcutCache.removeValue(forKey: action)
        defaults.removeObject(forKey: "shortcut_\(action.rawValue)")
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    func resetAllShortcuts() {
        shortcutCache.removeAll()
        for action in ShortcutAction.allCases {
            defaults.removeObject(forKey: "shortcut_\(action.rawValue)")
        }
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }
}

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("shortcutsChanged")
}

// MARK: - SwiftUI KeyboardShortcut conversion

import SwiftUI

extension KeyShortcut {
    var swiftUIKeyboardShortcut: KeyboardShortcut? {
        guard let keyEquivalent = swiftUIKeyEquivalent else { return nil }
        return KeyboardShortcut(keyEquivalent, modifiers: swiftUIModifiers)
    }

    private var swiftUIKeyEquivalent: KeyEquivalent? {
        switch key.lowercased() {
        case "⌫", "delete": return .delete
        case "⏎", "return": return .return
        case "⇥", "tab": return .tab
        case "space", " ": return .space
        case "⎋", "escape": return .escape
        case "↑", "uparrow": return .upArrow
        case "↓", "downarrow": return .downArrow
        case "←", "leftarrow": return .leftArrow
        case "→", "rightarrow": return .rightArrow
        case "home": return .home
        case "end": return .end
        case "pgup": return .pageUp
        case "pgdn": return .pageDown
        default:
            guard let char = key.lowercased().first else { return nil }
            return KeyEquivalent(char)
        }
    }

    private var swiftUIModifiers: SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return m
    }
}
