import SwiftUI

// MARK: - Plain Text Preview Floating Panel (`[` / `]`)

/// A Finder-style floating panel that renders the beginning of *any* file
/// as plain text. Unlike Quick Look it never asks the system for a rich
/// preview — it just reads up to `SettingsManager.textPreviewByteLimit`
/// bytes and shows them, so binary files, unknown extensions, source code,
/// logs, etc. can all be inspected instantly.
///
/// Behaviour mirrors `QuickLookPanelController`: the panel floats above the
/// main window, and while it's visible the arrow keys move the main-window
/// selection and the panel auto-updates to the newly selected file.
@MainActor
class TextPreviewPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var scrollView: NSScrollView?
    private(set) var isVisible: Bool = false
    private var currentURL: URL?

    // Overlay HUD (file name + byte info)
    private var overlayView: NSVisualEffectView?
    private var nameLabel: NSTextField?
    private var infoLabel: NSTextField?

    func togglePreview(for url: URL) {
        if let p = panel, p.isVisible {
            close()
        } else {
            show(url: url)
        }
    }

    func updatePreview(for url: URL) {
        guard isVisible, let p = panel, p.isVisible else { return }
        load(url: url)
    }

    func isTextViewFirstResponder(in window: NSWindow?) -> Bool {
        guard let panel, let textView, window === panel else { return false }
        return panel.firstResponder === textView
    }

    // MARK: Text loading

    /// Read up to the configured byte limit and decode into text. Returns
    /// the decoded string plus whether the file was truncated and the
    /// total file size in bytes.
    private func loadText(from url: URL) -> (text: String, truncated: Bool, totalBytes: Int) {
        let limit = SettingsManager.shared.textPreviewByteLimit

        // Directories can't be read as text.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return ("〔这是一个文件夹，无法作为文本预览〕", false, 0)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ("〔无法打开文件：\(url.lastPathComponent)〕", false, 0)
        }
        defer { try? handle.close() }

        let totalBytes = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let data = handle.readData(ofLength: limit)
        let truncated = data.count < totalBytes
        return (Self.decode(data), truncated, totalBytes)
    }

    /// Decode raw bytes into a String, trying a few common encodings. Reads
    /// may cut a multi-byte character in half at the byte limit, so each
    /// encoding is retried after dropping up to a few trailing bytes.
    private static func decode(_ data: Data) -> String {
        if data.isEmpty { return "〔空文件〕" }

        let gb18030 = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let encodings: [String.Encoding] = [.utf8, gb18030, .isoLatin1]

        for enc in encodings {
            let maxDrop = min(4, data.count)
            for drop in 0..<maxDrop {
                let slice = data.subdata(in: 0..<(data.count - drop))
                if let s = String(data: slice, encoding: enc), !s.isEmpty {
                    return s
                }
            }
        }
        // Lossy fallback — never fails, replaces invalid bytes.
        return String(decoding: data, as: UTF8.self)
    }

    private func load(url: URL) {
        let result = loadText(from: url)
        textView?.string = result.text
        // Scroll back to the top for the new file.
        textView?.scroll(NSPoint.zero)
        currentURL = url
        panel?.title = url.lastPathComponent
        updateOverlay(url: url, truncated: result.truncated, totalBytes: result.totalBytes)
    }

    // MARK: Panel lifecycle

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { close() }
        return false
    }

    private func show(url: URL) {
        let isFirstShow = (panel == nil)
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = false
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            p.animationBehavior = .utilityWindow
            p.minSize = NSSize(width: 300, height: 250)
            p.delegate = self

            guard let contentView = p.contentView else { return }

            let scroll = NSScrollView(frame: contentView.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.borderType = .noBorder
            scroll.drawsBackground = true

            let tv = NSTextView(frame: contentView.bounds)
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.drawsBackground = true
            tv.backgroundColor = .textBackgroundColor
            tv.textColor = .textColor
            tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
            tv.minSize = NSSize(width: 0, height: 0)
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)

            scroll.documentView = tv
            contentView.addSubview(scroll)

            self.panel = p
            self.scrollView = scroll
            self.textView = tv
            installOverlay(on: contentView)
        }

        load(url: url)

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

    func close() {
        guard let panel = panel, isVisible else { return }
        isVisible = false
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

    // MARK: Overlay HUD

    private func installOverlay(on contentView: NSView) {
        let bar = NSVisualEffectView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.layer?.masksToBounds = true

        let name = NSTextField(labelWithString: "")
        name.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        name.textColor = .labelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let info = NSTextField(labelWithString: "")
        info.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        info.textColor = .secondaryLabelColor
        info.alignment = .center

        let stack = NSStackView(views: [name, info])
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
        ])

        self.overlayView = bar
        self.nameLabel = name
        self.infoLabel = info
    }

    private func updateOverlay(url: URL, truncated: Bool, totalBytes: Int) {
        nameLabel?.stringValue = url.lastPathComponent
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if totalBytes > 0 {
            let sizeText = formatter.string(fromByteCount: Int64(totalBytes))
            if truncated {
                let limitText = formatter.string(
                    fromByteCount: Int64(SettingsManager.shared.textPreviewByteLimit))
                infoLabel?.stringValue = "\(sizeText) · 仅显示前 \(limitText)"
            } else {
                infoLabel?.stringValue = sizeText
            }
        } else {
            infoLabel?.stringValue = ""
        }
        infoLabel?.isHidden = (infoLabel?.stringValue.isEmpty ?? true)
    }
}
