import Foundation

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let url: URL
    let section: SidebarSection
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
            ("Desktop", "menubar.dock.rectangle", "Desktop"),
            ("Documents", "doc.on.doc.fill", "Documents"),
            ("Downloads", "arrow.down.circle.fill", "Downloads"),
            ("Applications", "app.fill", "/Applications"),
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
        if let volumes = try? FileManager.default.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: [.isVolumeKey], options: []) {
            for volume in volumes {
                let name = volume.lastPathComponent
                if name == "Macintosh HD" { continue }
                items.append(SidebarItem(id: "loc_\(name)", name: name, icon: "externaldrive.fill", url: volume, section: .locations))
            }
        }

        // Home folder
        items.append(SidebarItem(id: "loc_home", name: NSUserName(), icon: "house.fill", url: homeURL, section: .locations))

        return items
    }
}
