import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileDropTarget<Content: View>: NSViewRepresentable {
    let content: Content
    let allowsDrop: () -> Bool
    let onDrop: (NSPasteboard) -> Void

    func makeNSView(context: Context) -> FileDropTargetView {
        let view = FileDropTargetView(frame: .zero)
        let host = NSHostingView(rootView: AnyView(content.environment(\.self, context.environment)))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.allowsDrop = allowsDrop
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: FileDropTargetView, context: Context) {
        (view.subviews.first as? NSHostingView<AnyView>)?.rootView =
            AnyView(content.environment(\.self, context.environment))
        view.allowsDrop = allowsDrop
        view.onDrop = onDrop
    }
}

final class FileDropTargetView: NSView {
    var allowsDrop: (() -> Bool)?
    var onDrop: ((NSPasteboard) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
                + [.fileURL, .URL, .png, .tiff, NSPasteboard.PasteboardType(UTType.image.identifier)]
                + [NSPasteboard.PasteboardType("NSFilenamesPboardType")]
                + BrowserDropImporter.imageTypes.map { NSPasteboard.PasteboardType($0.identifier) }
        )
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(for: sender.draggingPasteboard)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(for: sender.draggingPasteboard)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !operation(for: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !operation(for: sender.draggingPasteboard).isEmpty, let onDrop else { return false }
        onDrop(sender.draggingPasteboard)
        return true
    }

    func operation(for pasteboard: NSPasteboard) -> NSDragOperation {
        guard allowsDrop?() == true,
              pasteboard.availableType(from: registeredDraggedTypes) != nil else { return [] }
        // A promise delivers a copy; Shift must never delete its remote source.
        if Self.hasFilePromises(pasteboard), FileDragNSView.draggedURLs == nil { return .copy }
        return NSEvent.modifierFlags.contains(.shift) ? .move : .copy
    }

    static func hasFilePromises(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from:
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        ) != nil
    }

    static func itemProviders(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        (pasteboard.pasteboardItems ?? []).flatMap { item -> [NSItemProvider] in
            if !item.types.contains(.fileURL),
               item.types.contains(.init("NSFilenamesPboardType")),
               let paths = item.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
                return paths.map { path in
                    let provider = NSItemProvider()
                    let data = URL(fileURLWithPath: path).dataRepresentation
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                        completion(data, nil)
                        return nil
                    }
                    return provider
                }
            }
            let provider = NSItemProvider()
            for type in item.types {
                guard type == .fileURL || type == .URL
                        || UTType(type.rawValue)?.conforms(to: .image) == true else { continue }
                guard let data = item.data(forType: type) else { continue }
                provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider.registeredTypeIdentifiers.isEmpty ? [] : [provider]
        }
    }
}
