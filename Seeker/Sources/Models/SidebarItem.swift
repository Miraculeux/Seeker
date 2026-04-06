import Foundation

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let url: URL
    let section: SidebarSection
    var isEjectable: Bool = false
    var isTrash: Bool = false
}

enum SidebarSection: String, CaseIterable {
    case favorites = "Favorites"
    case locations = "Locations"
}

struct SidebarDefaults {
    static func defaultItems() -> [SidebarItem] {
        var items: [SidebarItem] = []

        // Favorites
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let favorites: [(String, String, String)] = [
            ("Applications", "app.fill", "/Applications"),
            ("Desktop", "menubar.dock.rectangle", "Desktop"),
            ("Documents", "doc.on.doc.fill", "Documents"),
            ("Downloads", "arrow.down.circle.fill", "Downloads"),
        ]

        for (name, icon, path) in favorites {
            let url: URL
            if path.hasPrefix("/") {
                url = URL(fileURLWithPath: path)
            } else {
                url = homeURL.appendingPathComponent(path)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                items.append(SidebarItem(id: "fav_\(name)", name: name, icon: icon, url: url, section: .favorites))
            }
        }

        // Locations - root disk
        let rootURL = URL(fileURLWithPath: "/")
        items.append(SidebarItem(id: "loc_root", name: "Macintosh HD", icon: "internaldrive.fill", url: rootURL, section: .locations))

        // External volumes
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        if let volumes = try? FileManager.default.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey], options: []) {
            for volume in volumes {
                let name = volume.lastPathComponent
                if name == "Macintosh HD" { continue }
                let rv = try? volume.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey])
                let ejectable = (rv?.volumeIsEjectable == true) || (rv?.volumeIsRemovable == true) || (rv?.volumeIsInternal == false)
                items.append(SidebarItem(id: "loc_\(name)", name: name, icon: "externaldrive.fill", url: volume, section: .locations, isEjectable: ejectable))
            }
        }

        // Home folder
        items.append(SidebarItem(id: "loc_home", name: NSUserName(), icon: "house.fill", url: homeURL, section: .locations))

        // Trash
        let trashURL = homeURL.appendingPathComponent(".Trash")
        items.append(SidebarItem(id: "loc_trash", name: "Trash", icon: "trash.fill", url: trashURL, section: .locations, isTrash: true))

        return items
    }
}
