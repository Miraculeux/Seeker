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
                                HStack(spacing: 4) {
                                    Text(section.rawValue.uppercased())
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .tracking(0.5)
                                    Spacer()
                                    if section == .favorites {
                                        Button {
                                            promptAddFavorite()
                                        } label: {
                                            Image(systemName: "plus")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.secondary.opacity(0.6))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Add Folder to Favorites…")
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.bottom, 4)

                                ForEach(sectionItems) { item in
                                    SidebarRow(item: item)
                                        .padding(.horizontal, 6)
                                }
                            }
                            .if(section == .favorites) { view in
                                view.onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                    handleFavoritesDrop(providers: providers)
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
        .onReceive(NotificationCenter.default.publisher(for: .favoritesChanged)) { _ in
            sidebarItems = SidebarDefaults.defaultItems()
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

    // MARK: - Favorites helpers

    private func promptAddFavorite() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Favorites"
        panel.message = "Choose folders to add to your favorites"
        if panel.runModal() == .OK {
            for url in panel.urls {
                SettingsManager.shared.addFavorite(url)
            }
        }
    }

    private func handleFavoritesDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.isFileURL else { return }
                DispatchQueue.main.async {
                    SettingsManager.shared.addFavorite(url)
                }
            }
        }
        return true
    }
}

// Lightweight conditional view modifier so the favorites section can opt
// into a drop target without forcing it on every section.
private extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition { transform(self) } else { self }
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
        .contextMenu {
            Button("Open in New Tab") {
                let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
                pane.addTab(url: item.url)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            if item.isUserFavorite {
                Divider()
                Button("Remove from Favorites") {
                    SettingsManager.shared.removeFavorite(item.url)
                }
            }
        }
    }

    private func ejectVolume(at url: URL) {
        let volumeName = url.lastPathComponent
        Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t Eject “\(volumeName)”"
                    alert.informativeText = friendlyEjectErrorMessage(for: error, volumeName: volumeName)
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    /// Translates the cryptic `OSStatus` errors returned by
    /// `unmountAndEjectDevice` into actionable, user-facing messages.
    private func friendlyEjectErrorMessage(for error: Error, volumeName: String) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case -47: // fBsyErr — file/volume is busy
            return "“\(volumeName)” is in use. Quit any apps using files on the disk (including Terminal windows or Finder previews), then try again."
        case -49: // opWrErr — file open with write permission
            return "A file on “\(volumeName)” is still open for writing. Save and close any documents stored on the disk, then try again."
        case -50: // paramErr
            return "The disk couldn’t be ejected because the request was invalid. Try again, or eject from Finder."
        case -35: // nsvErr — no such volume
            return "“\(volumeName)” is no longer available. It may have already been ejected."
        case -61: // wrPermErr
            return "Seeker doesn’t have permission to eject “\(volumeName)”. Try ejecting it from Finder."
        default:
            return error.localizedDescription
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
