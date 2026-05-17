import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Modal sheet for editing audio/video tag metadata via `MediaMetadataService`.
///
/// Single-file mode shows the cover art and an editable table of tag rows
/// (key + value) backed by `MediaMetadata.Tag`. Users can rename keys,
/// edit values, delete rows, or add new rows. Cover art can be replaced or
/// removed using "Choose…" / "Remove" buttons.
///
/// Batch mode (multi-selection) shows a simplified form for the standard
/// tag keys (`TITLE`, `ARTIST`, `ALBUM`, `ALBUMARTIST`, `DATE`, `GENRE`,
/// `COMPOSER`, `COMMENT`). Only fields the user actually edits are applied
/// to every file; empty fields are left untouched.
struct MediaMetadataEditorSheet: View {
    let targets: [URL]
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var meta = MediaMetadata()
    @State private var original = MediaMetadata()

    // Batch-mode fields (only used when targets.count > 1).
    @State private var batchFields: [String: String] = [:]

    @State private var errorMessage: String?
    @State private var saving: Bool = false

    private var isBatch: Bool { targets.count > 1 }
    private var firstTarget: URL? { targets.first }

    /// True when every selected target is in a read-only format (no writer).
    private var isReadOnly: Bool {
        !targets.isEmpty && targets.allSatisfy(MediaMetadataService.isReadOnly)
    }

    private static let batchKeys = [
        "TITLE", "ARTIST", "ALBUMARTIST", "ALBUM", "DATE",
        "GENRE", "TRACKNUMBER", "DISCNUMBER", "COMPOSER", "COMMENT"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isReadOnly { readOnlyNotice }
                    if isBatch {
                        batchNotice
                        batchForm
                    } else {
                        singleEditor
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .onAppear(perform: load)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(isBatch ? "Edit Media Tags" : (firstTarget?.lastPathComponent ?? "Edit Media Tags"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isBatch
                     ? "\(targets.count) files selected"
                     : (firstTarget?.deletingLastPathComponent().path ?? ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Revert") { load() }
                .disabled(saving || isReadOnly)
            Button(isReadOnly ? "Close" : "Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            if !isReadOnly {
                Button(isBatch ? "Apply to \(targets.count)" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(12)
    }

    private var batchNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .foregroundColor(.orange)
            Text("Batch mode — only non-empty fields will be written to every file. Existing tags not listed here are preserved.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }

    private var readOnlyNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .foregroundColor(.secondary)
            Text("Read-only — Seeker can display tags for this format but cannot write them.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: - Single-file editor

    private var singleEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                coverArtView
                VStack(alignment: .leading, spacing: 6) {
                    if let vendor = meta.vendor, !vendor.isEmpty {
                        labeledRow("Vendor", vendor)
                    }
                    labeledRow("Format", firstTarget?.pathExtension.uppercased() ?? "")
                    labeledRow("Tags", "\(meta.tags.count)")
                    Spacer(minLength: 0)
                }
                Spacer()
            }
            Divider()
            tagRows
        }
    }

    private var coverArtView: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                if let data = meta.coverArt, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(6)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .frame(width: 140, height: 140)

            HStack(spacing: 6) {
                Button("Choose…") { pickCover() }
                    .controlSize(.small)
                if meta.coverArt != nil {
                    Button("Remove") {
                        meta.coverArt = nil
                        meta.coverMimeType = nil
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var tagRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tags").font(.subheadline.bold())
                Spacer()
                Button {
                    meta.tags.append(.init(key: "", value: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .help("Add new tag row")
                .disabled(isReadOnly)
            }
            ForEach($meta.tags) { $tag in
                HStack(spacing: 6) {
                    TextField("KEY", text: $tag.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isReadOnly)
                    TextField("value", text: $tag.value, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(isReadOnly)
                    Button {
                        meta.tags.removeAll { $0.id == tag.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove tag")
                    .disabled(isReadOnly)
                }
            }
            if meta.tags.isEmpty {
                Text(isReadOnly ? "No tags found." : "No tags. Click + to add one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Batch form

    private var batchForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.batchKeys, id: \.self) { key in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 130, alignment: .leading)
                        .foregroundColor(.secondary)
                    TextField("", text: Binding(
                        get: { batchFields[key] ?? "" },
                        set: { batchFields[key] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            Text("Tip: To clear a tag across files, type a single space.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Load / Save

    private func load() {
        errorMessage = nil
        if isBatch {
            batchFields = [:]
            return
        }
        guard let url = firstTarget else { return }
        do {
            let m = try MediaMetadataService.read(url)
            meta = m
            original = m
        } catch {
            errorMessage = "Failed to read tags: \(error.localizedDescription)"
            meta = MediaMetadata()
            original = MediaMetadata()
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        if isBatch {
            saveBatch()
        } else {
            saveSingle()
        }
    }

    private func saveSingle() {
        guard let url = firstTarget else { saving = false; return }
        let toWrite = meta
        Task.detached(priority: .userInitiated) {
            do {
                try MediaMetadataService.write(toWrite, to: url)
                await MainActor.run {
                    saving = false
                    close()
                }
            } catch {
                await MainActor.run {
                    saving = false
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveBatch() {
        // Only fields the user actually typed are applied. A single-space
        // value is treated as an explicit "clear this tag".
        let edits = batchFields.compactMap { (k, v) -> (String, String)? in
            v.isEmpty ? nil : (k, v == " " ? "" : v)
        }
        if edits.isEmpty { saving = false; close(); return }

        let urls = targets
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for url in urls {
                do {
                    var current = (try? MediaMetadataService.read(url)) ?? MediaMetadata()
                    for (key, value) in edits {
                        if let idx = current.tags.firstIndex(where: {
                            $0.key.caseInsensitiveCompare(key) == .orderedSame
                        }) {
                            if value.isEmpty {
                                current.tags.remove(at: idx)
                            } else {
                                current.tags[idx].value = value
                            }
                        } else if !value.isEmpty {
                            current.tags.append(.init(key: key, value: value))
                        }
                    }
                    try MediaMetadataService.write(current, to: url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let failuresSnapshot = failures
            await MainActor.run {
                saving = false
                if failuresSnapshot.isEmpty {
                    close()
                } else {
                    errorMessage = "Failed on \(failuresSnapshot.count) file(s). First: \(failuresSnapshot[0])"
                }
            }
        }
    }

    private func close() {
        dismiss()
        onClose()
    }

    // MARK: - Cover art picker

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            meta.coverArt = data
            meta.coverMimeType = url.pathExtension.lowercased() == "png"
                ? "image/png" : "image/jpeg"
        }
    }
}
