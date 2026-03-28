import Foundation

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
