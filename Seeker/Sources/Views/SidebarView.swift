import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppState.self) var appState
    @State private var sidebarItems = SidebarDefaults.defaultItems()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(SidebarSection.allCases, id: \.self) { section in
                        let sectionItems = sidebarItems.filter { $0.section == section }
                        if !sectionItems.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.rawValue.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .tracking(0.5)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 4)

                                ForEach(sectionItems) { item in
                                    SidebarRow(item: item)
                                        .padding(.horizontal, 6)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            sidebarItems = SidebarDefaults.defaultItems()
            // Refresh any tab viewing /Volumes so the new disk appears
            let volumesDir = URL(fileURLWithPath: "/Volumes").standardizedFileURL
            for pane in [appState.leftPane, appState.rightPane] {
                for tab in pane.tabs where tab.currentURL.standardizedFileURL == volumesDir {
                    tab.loadFiles()
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { notification in
            // Immediately remove the ejected volume to avoid race with filesystem
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                sidebarItems.removeAll { $0.url.standardizedFileURL == volumeURL.standardizedFileURL }

                // Navigate panes away from the ejected volume, and refresh any viewing /Volumes
                let home = FileManager.default.homeDirectoryForCurrentUser
                let volumePath = volumeURL.standardizedFileURL.path
                let volumesDir = URL(fileURLWithPath: "/Volumes").standardizedFileURL
                for pane in [appState.leftPane, appState.rightPane] {
                    for tab in pane.tabs {
                        let tabPath = tab.currentURL.standardizedFileURL
                        if tabPath.path.hasPrefix(volumePath) {
                            tab.navigateTo(home)
                        } else if tabPath == volumesDir {
                            tab.loadFiles()
                        }
                    }
                }
            }
            // Single re-enumeration; the previous code did this twice (once
            // immediately, once after a 0.5s `asyncAfter` sleep poll).
            sidebarItems = SidebarDefaults.defaultItems()
        }
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    @Environment(AppState.self) var appState
    @State private var hovering = false

    private var isActive: Bool {
        appState.activeExplorer.currentURL == item.url
    }

    var body: some View {
        Button {
            appState.navigateActivePane(to: item.url)
        } label: {
            HStack(spacing: 7) {
                Group {
                    if item.isTrash {
                        Image(systemName: "trash.fill")
                            .foregroundColor(.secondary)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: 16, height: 16)
                Text(item.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .primary : (hovering ? .primary : .secondary.opacity(0.9)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if item.isTrash && hovering {
                    Button {
                        emptyTrash()
                    } label: {
                        Image(systemName: "trash.slash.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Empty Trash")
                }
                if item.isEjectable && hovering {
                    Button {
                        ejectVolume(at: item.url)
                    } label: {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Eject \(item.name)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovering)
        .animation(.easeInOut(duration: 0.1), value: isActive)
    }

    private func ejectVolume(at url: URL) {
        Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Eject Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    private func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "All items in the Trash will be permanently deleted. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let script = """
            tell application "Finder"
                empty the trash
            end tell
            """
        if let appleScript = NSAppleScript(source: script) {
            var errorInfo: NSDictionary?
            let result = appleScript.executeAndReturnError(&errorInfo)
            if result.descriptorType == typeNull, let errorInfo = errorInfo,
               let errorMsg = errorInfo[NSAppleScript.errorMessage] as? String {
                let errAlert = NSAlert()
                errAlert.messageText = "Failed to Empty Trash"
                errAlert.informativeText = errorMsg
                errAlert.alertStyle = .warning
                errAlert.runModal()
            } else {
                let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                if appState.activeExplorer.currentURL == trashURL {
                    appState.activeExplorer.loadFiles()
                }
            }
        }
    }
}
