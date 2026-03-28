import Foundation

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
    }

    var rememberLastLocation: Bool {
        get { defaults.bool(forKey: Keys.rememberLastLocation) }
        set { defaults.set(newValue, forKey: Keys.rememberLastLocation) }
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
        set { defaults.set(newValue, forKey: Keys.showSizeColumn) }
    }

    var showModifiedColumn: Bool {
        get { defaults.object(forKey: Keys.showModifiedColumn) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showModifiedColumn) }
    }

    var showKindColumn: Bool {
        get { defaults.object(forKey: Keys.showKindColumn) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showKindColumn) }
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

    var visibleColumnsOrdered: [ColumnID] {
        columnOrder.filter { isColumnVisible($0) }
    }

    var lastLeftPanePath: String? {
        get { defaults.string(forKey: Keys.leftPanePath) }
        set { defaults.set(newValue, forKey: Keys.leftPanePath) }
    }

    var lastRightPanePath: String? {
        get { defaults.string(forKey: Keys.rightPanePath) }
        set { defaults.set(newValue, forKey: Keys.rightPanePath) }
    }

    func saveLocations(left: URL, right: URL) {
        lastLeftPanePath = left.path
        lastRightPanePath = right.path
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
}
