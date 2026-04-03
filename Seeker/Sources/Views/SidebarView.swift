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
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
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
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                Text(item.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .primary : (hovering ? .primary : .secondary.opacity(0.9)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
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
}
