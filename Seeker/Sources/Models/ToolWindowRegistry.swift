import AppKit
import Observation

enum ToolWindowKind: CaseIterable {
    case duplicates, compare, search, similarImages, semanticSearch, sync

    var title: String {
        switch self {
        case .duplicates: "Find Duplicates"
        case .compare: "Compare Folders"
        case .search: "Search"
        case .similarImages: "Similar Images"
        case .semanticSearch: "Semantic Search"
        case .sync: "Sync Folders"
        }
    }

    var symbol: String {
        switch self {
        case .duplicates: "doc.on.doc"
        case .compare: "rectangle.split.2x1"
        case .search: "magnifyingglass"
        case .similarImages: "photo.on.rectangle"
        case .semanticSearch: "sparkle.magnifyingglass"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}

@MainActor @Observable
final class ToolWindowRegistry {
    static let shared = ToolWindowRegistry()

    struct Entry: Identifiable {
        let id: ObjectIdentifier
        let ownerID: UUID
        let sourceWindowID: UUID
        let kind: ToolWindowKind
        let urls: [URL]
        weak var window: NSWindow?

        var label: String {
            let names = urls.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
            return ([kind.title] + names).joined(separator: " \u{00B7} ")
        }

        var help: String {
            ([kind.title] + urls.map(\.path) + ["Click to bring this window to the front."])
                .joined(separator: "\n")
        }
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    init() {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.entries.removeAll { $0.id == ObjectIdentifier(window) }
            }
        }
    }

    isolated deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    func register(window: NSWindow, ownerID: UUID, sourceWindowID: UUID, kind: ToolWindowKind, urls: [URL]) {
        entries.removeAll { $0.window == nil }
        let entry = Entry(id: ObjectIdentifier(window), ownerID: ownerID,
                          sourceWindowID: sourceWindowID, kind: kind, urls: urls, window: window)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            let previous = entries[index]
            guard previous.ownerID != ownerID || previous.sourceWindowID != sourceWindowID
                    || previous.kind != kind || previous.urls != urls else { return }
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    func unregister(ownerID: UUID) {
        entries.removeAll { $0.ownerID == ownerID || $0.window == nil }
    }

    func windows(for sourceWindowID: UUID) -> [Entry] {
        entries.filter { $0.sourceWindowID == sourceWindowID && $0.window != nil }
    }

    func activate(_ id: ObjectIdentifier) {
        guard let window = entries.first(where: { $0.id == id })?.window else {
            entries.removeAll { $0.window == nil }
            NSSound.beep()
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.attachedSheet?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
