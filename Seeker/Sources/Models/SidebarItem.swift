import Foundation

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let url: URL
    let section: SidebarSection
    var isEjectable: Bool = false
    var isTrash: Bool = false
    var isUserFavorite: Bool = false
}

enum SidebarSection: String, CaseIterable {
    case favorites = "Favorites"
    case locations = "Locations"
}

struct SidebarDefaults {
    @MainActor
    static func defaultItems() -> [SidebarItem] {
        var items: [SidebarItem] = []

        // Favorites
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let favorites: [(String, String, String)] = [
            ("Applications", "pencil.and.ruler", "/Applications"),
            ("Desktop", "menubar.dock.rectangle", "Desktop"),
            ("Documents", "doc", "Documents"),
            ("Downloads", "arrow.down.circle", "Downloads"),
        ]

        for (name, icon, path) in favorites {
            let url: URL
            if path.hasPrefix("/") {
                url = URL(fileURLWithPath: path)
            } else {
                url = homeURL.appendingPathComponent(path)
            }
            items.append(SidebarItem(id: "fav_\(name)", name: name, icon: icon, url: url, section: .favorites))
        }

        // User-added favorites
        for path in SettingsManager.shared.userFavoritePaths {
            let url = URL(fileURLWithPath: path)
            // Skip stale entries that no longer resolve to a directory.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
            items.append(SidebarItem(
                id: "userfav_\(path)",
                name: name,
                icon: "folder",
                url: url,
                section: .favorites,
                isUserFavorite: true
            ))
        }

        // Home folder
        items.append(SidebarItem(id: "loc_home", name: NSUserName(), icon: "house", url: homeURL, section: .locations))
        items.append(SidebarItem(
            id: "loc_computer", name: ComputerLocation.name, icon: "macmini.fill",
            url: ComputerLocation.url, section: .locations
        ))

        do {
            for volume in try ComputerLocation.volumes() {
                let values = try volume.resourceValues(forKeys: ComputerLocation.volumeKeys)
                let isRoot = volume.path == "/"
                let ejectable = !isRoot && (
                    values.volumeIsEjectable == true || values.volumeIsRemovable == true
                        || values.volumeIsInternal == false
                )
                items.append(SidebarItem(
                    id: isRoot ? "loc_root" : "loc_\(volume.path)",
                    name: values.volumeName ?? volume.lastPathComponent,
                    icon: values.volumeIsInternal == true ? "internaldrive" : "externaldrive",
                    url: volume, section: .locations, isEjectable: ejectable
                ))
            }
        } catch {
            NSLog("Seeker: Could not load sidebar volumes: %@", error.localizedDescription)
        }

        // Trash
        let trashURL = homeURL.appendingPathComponent(".Trash")
        items.append(SidebarItem(id: "loc_trash", name: "Trash", icon: "trash", url: trashURL, section: .locations, isTrash: true))

        return items
    }
}
