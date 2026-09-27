import SwiftUI
import AppKit

struct ToolWindowBar: View {
    let sourceWindowID: UUID
    private let registry = ToolWindowRegistry.shared

    var body: some View {
        let entries = registry.windows(for: sourceWindowID)
        if !entries.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    Text("Tools")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(entries) { entry in
                                Button {
                                    registry.activate(entry.id)
                                } label: {
                                    Label(entry.label, systemImage: entry.kind.symbol)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: 300)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(entry.help)
                                .accessibilityLabel(entry.label)
                                .accessibilityHint("Bring the existing tool window to the front")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.bar)
            }
        }
    }
}

struct ToolWindowURLsKey: PreferenceKey {
    static let defaultValue: [URL]? = nil

    static func reduce(value: inout [URL]?, nextValue: () -> [URL]?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    func toolWindowURLs(_ urls: [URL]) -> some View {
        preference(key: ToolWindowURLsKey.self, value: urls)
    }
}

struct ToolWindowRegistrationView: NSViewRepresentable {
    let sourceWindowID: UUID
    let kind: ToolWindowKind
    let urls: [URL]

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView()
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.configuration = self
        nsView.scheduleRegistration()
    }

    static func dismantleNSView(_ nsView: RegistrationView, coordinator: ()) {
        nsView.configuration = nil
        nsView.scheduleRegistration()
    }

    final class RegistrationView: NSView {
        let ownerID = UUID()
        var configuration: ToolWindowRegistrationView?
        private weak var observedWindow: NSWindow?
        private var closeObserver: NSObjectProtocol?
        private var isClosed = false

        isolated deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleRegistration()
        }

        func scheduleRegistration() {
            if observedWindow !== window {
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                closeObserver = nil
                observedWindow = window
                isClosed = false
                if let window {
                    closeObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification, object: window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.isClosed = true }
                    }
                }
            }
            // Publishing during an AppKit/SwiftUI update can cause reentrant
            // layout. Resolve the current attachment on the next main turn.
            let ownerID = ownerID
            DispatchQueue.main.async { [weak self] in
                guard let self, !isClosed, let configuration, let window else {
                    ToolWindowRegistry.shared.unregister(ownerID: ownerID)
                    return
                }
                ToolWindowRegistry.shared.register(
                    window: window, ownerID: ownerID, sourceWindowID: configuration.sourceWindowID,
                    kind: configuration.kind, urls: configuration.urls
                )
            }
        }
    }
}
