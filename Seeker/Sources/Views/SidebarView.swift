import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppState.self) var appState
    let sidebarItems = SidebarDefaults.defaultItems()

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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.navigateActivePane(to: item.url)
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovering)
        .animation(.easeInOut(duration: 0.1), value: isActive)
    }
}
