import SwiftUI
import QuickLookUI

// MARK: - Quick Look Preview

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as QLPreviewItem
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }

    // Clear the preview item when the wrapper goes away so QLPreviewView
    // tears down its internal AVPlayer and stops any in-progress audio /
    // video playback (mp3, m4a, wav, mp4, mov, …). Without this, media
    // can keep playing after the sheet is dismissed.
    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.previewItem = nil
    }
}

// MARK: - Quick Look Floating Panel (Finder-style)

@MainActor
class QuickLookPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var previewView: QLPreviewView?
    private(set) var isVisible: Bool = false
    private var currentURL: URL?

    // MARK: Overlay HUD (file name + auto-preview controls)
    private var overlayView: NSVisualEffectView?
    private var nameLabel: NSTextField?
    private var counterLabel: NSTextField?
    private var pauseButton: NSButton?

    // MARK: Auto-preview state
    private var autoPreviewURLs: [URL] = []
    private var autoPreviewIndex: Int = 0
    private var autoPreviewTimer: Timer?
    private var autoPreviewInterval: TimeInterval = 1.5
    /// True while a slideshow is active (running or paused).
    private(set) var isAutoPreviewing: Bool = false
    /// True when the slideshow is active but the timer is currently paused.
    private(set) var isAutoPreviewPaused: Bool = false

    func togglePreview(for url: URL) {
        if let p = panel, p.isVisible {
            close()
        } else {
            stopAutoPreview()
            show(url: url)
        }
    }

    func updatePreview(for url: URL) {
        guard isVisible, let p = panel, p.isVisible else { return }
        previewView?.previewItem = url as QLPreviewItem
        currentURL = url
        panel?.title = url.lastPathComponent
        // If a slideshow is active (running or paused) and the new URL
        // is one of its tracked entries, advance the index so the HUD's
        // counter and file name stay in sync with the externally-driven
        // selection. Without this, the overlay keeps reading
        // `autoPreviewURLs[autoPreviewIndex]` and shows the stale name.
        if isAutoPreviewing,
           let i = autoPreviewURLs.firstIndex(of: url) {
            autoPreviewIndex = i
        }
        updateOverlay()
    }

    /// Start an auto-advancing Quick Look slideshow over `urls`.
    /// The first URL is shown immediately; subsequent URLs are shown
    /// every `interval` seconds, looping back to the start. Stops if
    /// the panel is closed or `stopAutoPreview()` is called.
    func startAutoPreview(urls: [URL], interval: TimeInterval) {
        stopAutoPreview()
        guard let first = urls.first else { return }
        autoPreviewURLs = urls
        autoPreviewIndex = 0
        autoPreviewInterval = max(0.1, interval)
        show(url: first)
        guard urls.count > 1 else { return }
        isAutoPreviewing = true
        isAutoPreviewPaused = false
        scheduleAutoPreviewTimer()
        updateOverlay()
    }

    func stopAutoPreview() {
        autoPreviewTimer?.invalidate()
        autoPreviewTimer = nil
        autoPreviewURLs = []
        autoPreviewIndex = 0
        isAutoPreviewing = false
        isAutoPreviewPaused = false
        updateOverlay()
    }

    /// Pause the slideshow timer without losing position. No-op when
    /// auto-preview isn't active or is already paused.
    func pauseAutoPreview() {
        guard isAutoPreviewing, !isAutoPreviewPaused else { return }
        autoPreviewTimer?.invalidate()
        autoPreviewTimer = nil
        isAutoPreviewPaused = true
        updateOverlay()
    }

    /// Resume a paused slideshow at the current position. No-op when
    /// auto-preview isn't active or isn't paused.
    func resumeAutoPreview() {
        guard isAutoPreviewing, isAutoPreviewPaused else { return }
        isAutoPreviewPaused = false
        scheduleAutoPreviewTimer()
        updateOverlay()
    }

    /// Toggle paused/running. If auto-preview isn't active, does nothing.
    func toggleAutoPreviewPaused() {
        guard isAutoPreviewing else { return }
        if isAutoPreviewPaused {
            resumeAutoPreview()
        } else {
            pauseAutoPreview()
        }
    }

    private func scheduleAutoPreviewTimer() {
        autoPreviewTimer?.invalidate()
        let timer = Timer(timeInterval: autoPreviewInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceAutoPreview() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoPreviewTimer = timer
    }

    private func advanceAutoPreview() {
        guard !autoPreviewURLs.isEmpty,
              let panel = panel, panel.isVisible else {
            stopAutoPreview()
            return
        }
        autoPreviewIndex = (autoPreviewIndex + 1) % autoPreviewURLs.count
        let url = autoPreviewURLs[autoPreviewIndex]
        previewView?.previewItem = url as QLPreviewItem
        currentURL = url
        panel.title = url.lastPathComponent
        updateOverlay()
    }

    // Intercept close button — use orderOut instead of close
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            close()
        }
        return false // prevent NSWindow.close() from being called
    }

    private func show(url: URL) {
        let isFirstShow = (panel == nil)
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            p.animationBehavior = .utilityWindow
            p.minSize = NSSize(width: 300, height: 250)
            p.delegate = self

            guard let contentView = p.contentView,
                  let qlView = QLPreviewView(frame: contentView.bounds, style: .normal) else {
                return
            }
            qlView.autoresizingMask = [.width, .height]
            contentView.addSubview(qlView)

            self.panel = p
            self.previewView = qlView
            installOverlay(on: contentView)
        }

        previewView?.previewItem = url as QLPreviewItem
        currentURL = url
        panel?.title = url.lastPathComponent
        updateOverlay()

        // On first show, size the panel to fill the screen containing the
        // main window (leaving room for the menu bar / Dock). On subsequent
        // shows, preserve whatever size the user left it at and recenter
        // over the main window.
        if isFirstShow, let panel = panel {
            let referenceWindow = NSApp.mainWindow ?? NSApp.keyWindow
            let screen = referenceWindow?.screen ?? NSScreen.main
            if let visibleFrame = screen?.visibleFrame {
                panel.setFrame(visibleFrame, display: false)
            }
        } else if let mainWindow = NSApp.mainWindow ?? NSApp.keyWindow {
            let mainFrame = mainWindow.frame
            let panelSize = panel?.frame.size ?? NSSize(width: 600, height: 500)
            let x = mainFrame.midX - panelSize.width / 2
            let y = mainFrame.midY - panelSize.height / 2
            panel?.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel?.center()
        }

        panel?.alphaValue = 0
        panel?.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }

        isVisible = true
        NSApp.mainWindow?.makeKey()
    }

    // MARK: - Overlay HUD

    /// Build the translucent file-name + auto-preview controls bar and
    /// pin it to the bottom-center of the panel's content view.
    private func installOverlay(on contentView: NSView) {
        let bar = NSVisualEffectView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let counter = NSTextField(labelWithString: "")
        counter.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .center
        counter.isHidden = true

        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(pauseButtonClicked(_:))
        button.image = NSImage(
            systemSymbolName: "pause.fill",
            accessibilityDescription: "Pause"
        )
        button.contentTintColor = .labelColor
        button.isHidden = true

        let stack = NSStackView(views: [button, label, counter])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        bar.addSubview(stack)
        contentView.addSubview(bar)

        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),

            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),

            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])

        self.overlayView = bar
        self.nameLabel = label
        self.counterLabel = counter
        self.pauseButton = button
    }

    /// Refresh the overlay to reflect the current file name and the
    /// auto-preview state (visibility of pause button + counter).
    private func updateOverlay() {
        guard let bar = overlayView,
              let label = nameLabel,
              let counter = counterLabel,
              let button = pauseButton else { return }

        let displayURL: URL? = {
            // Prefer `currentURL` — it's the most recently shown item and
            // already kept in sync with both the timer-driven advance and
            // any externally-driven `updatePreview(for:)` call. Falling
            // back to the indexed slideshow URL only matters before the
            // very first frame is shown.
            if let u = currentURL { return u }
            if isAutoPreviewing, autoPreviewURLs.indices.contains(autoPreviewIndex) {
                return autoPreviewURLs[autoPreviewIndex]
            }
            return nil
        }()

        label.stringValue = displayURL?.lastPathComponent ?? ""

        if isAutoPreviewing {
            button.isHidden = false
            counter.isHidden = autoPreviewURLs.count < 2
            counter.stringValue = "\(autoPreviewIndex + 1) / \(autoPreviewURLs.count)"
            let symbol = isAutoPreviewPaused ? "play.fill" : "pause.fill"
            let desc = isAutoPreviewPaused ? "Resume" : "Pause"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
            button.toolTip = desc
        } else {
            button.isHidden = true
            counter.isHidden = true
        }
        bar.isHidden = label.stringValue.isEmpty
    }

    @objc private func pauseButtonClicked(_ sender: Any?) {
        toggleAutoPreviewPaused()
    }

    func close() {
        guard let panel = panel, isVisible else { return }
        isVisible = false
        stopAutoPreview()
        // Stop any in-flight media playback (e.g. MP3/MP4) immediately so
        // audio doesn't continue while the close animation runs or after
        // the panel is ordered out. QLPreviewView retains its AVPlayer-
        // backed preview controller until the previewItem is cleared.
        previewView?.previewItem = nil
        currentURL = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            MainActor.assumeIsolated {
                panel.animator().alphaValue = 0
            }
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }
}
