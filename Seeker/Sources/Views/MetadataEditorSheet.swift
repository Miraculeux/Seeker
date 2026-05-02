import SwiftUI
import AppKit
import CoreLocation

/// Modal sheet for viewing and editing the writable subset of EXIF/IPTC
/// metadata on one or more image files. Read-only camera fields are shown
/// in a collapsed section so users understand what cannot be changed.
struct MetadataEditorSheet: View {
    let targets: [URL]
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var meta = EditableMetadata.empty
    @State private var original = EditableMetadata.empty
    @State private var camera = ReadOnlyCameraInfo()
    @State private var keywordsText: String = ""
    @State private var latText: String = ""
    @State private var lonText: String = ""
    @State private var altText: String = ""
    @State private var hasLocation: Bool = false
    @State private var showCameraSection: Bool = false
    @State private var errorMessage: String?
    @State private var saving: Bool = false

    private var isBatch: Bool { targets.count > 1 }
    private var firstTarget: URL? { targets.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isBatch { batchNotice }
                    descriptiveFields
                    Divider()
                    timeField
                    Divider()
                    keywordsField
                    Divider()
                    ratingField
                    Divider()
                    gpsFields
                    if !isBatch { cameraReadOnly }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 640)
        .onAppear(perform: load)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(isBatch ? "Edit Metadata" : (firstTarget?.lastPathComponent ?? "Edit Metadata"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isBatch
                     ? "\(targets.count) images selected"
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

    private var batchNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .foregroundColor(.orange)
            Text("Batch mode — only non-empty fields will be applied to every file. Date and GPS are skipped unless changed.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
    }

    private var descriptiveFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Description")
            labeledField("Title / Description") {
                TextField("", text: $meta.imageDescription, axis: .vertical)
                    .lineLimit(2...4)
            }
            labeledField("Artist") {
                TextField("", text: $meta.artist)
            }
            labeledField("Copyright") {
                TextField("", text: $meta.copyright)
            }
            labeledField("User Comment") {
                TextField("", text: $meta.userComment, axis: .vertical)
                    .lineLimit(1...3)
            }
            labeledField("Software") {
                TextField("", text: $meta.software)
            }
        }
    }

    private var timeField: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Date Taken")
            HStack {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { meta.dateTimeOriginal ?? Date() },
                        set: { meta.dateTimeOriginal = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .disabled(meta.dateTimeOriginal == nil)
                Spacer()
                if meta.dateTimeOriginal == nil {
                    Button("Set") { meta.dateTimeOriginal = Date() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Clear") { meta.dateTimeOriginal = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var keywordsField: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Keywords")
            TextField("Comma-separated, e.g. travel, sunset, paris",
                      text: $keywordsText, axis: .vertical)
                .lineLimit(1...3)
                .onChange(of: keywordsText) { _, new in
                    meta.keywords = new
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
        }
    }

    private var ratingField: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Rating")
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Button {
                        meta.rating = (meta.rating == i) ? 0 : i
                    } label: {
                        Image(systemName: i <= meta.rating ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundColor(i <= meta.rating ? .yellow : .secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if meta.rating > 0 {
                    Button("Clear") { meta.rating = 0 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var gpsFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Location")
                Spacer()
                Toggle("", isOn: $hasLocation)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: hasLocation) { _, on in
                        if !on {
                            meta.location = nil
                            meta.altitude = nil
                            latText = ""; lonText = ""; altText = ""
                        } else if meta.location == nil {
                            meta.location = CLLocationCoordinate2D(latitude: 0, longitude: 0)
                            latText = "0.0"; lonText = "0.0"
                        }
                    }
            }
            if hasLocation {
                HStack(spacing: 8) {
                    labeledField("Latitude") {
                        TextField("-90 … 90", text: $latText)
                            .onChange(of: latText) { _, _ in syncCoord() }
                    }
                    labeledField("Longitude") {
                        TextField("-180 … 180", text: $lonText)
                            .onChange(of: lonText) { _, _ in syncCoord() }
                    }
                }
                labeledField("Altitude (m)") {
                    TextField("optional", text: $altText)
                        .onChange(of: altText) { _, new in
                            meta.altitude = Double(new.trimmingCharacters(in: .whitespaces))
                        }
                }
            } else {
                Text("No location stored.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var cameraReadOnly: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showCameraSection) {
                VStack(alignment: .leading, spacing: 6) {
                    readOnlyRow("Make", camera.make)
                    readOnlyRow("Model", camera.model)
                    readOnlyRow("Serial", camera.bodySerialNumber)
                    readOnlyRow("Lens", camera.lensModel)
                    readOnlyRow("Exposure", camera.exposureTime)
                    readOnlyRow("Aperture", camera.fNumber)
                    readOnlyRow("ISO", camera.iso)
                    readOnlyRow("Focal", camera.focalLength)
                    readOnlyRow("Pixels", camera.pixelDimensions)
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .foregroundColor(.secondary)
                    Text("Camera (read-only)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var footer: some View {
        HStack {
            if let err = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(err)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Revert") { load() }
                .disabled(saving)
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Button(isBatch ? "Apply to \(targets.count)" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundColor(.secondary)
    }

    private func labeledField<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func readOnlyRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary.opacity(0.7))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func syncCoord() {
        let lat = Double(latText.trimmingCharacters(in: .whitespaces))
        let lon = Double(lonText.trimmingCharacters(in: .whitespaces))
        if let lat, let lon,
           (-90...90).contains(lat), (-180...180).contains(lon) {
            meta.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            errorMessage = nil
        } else {
            errorMessage = "Latitude must be -90…90, longitude -180…180."
        }
    }

    private func load() {
        guard let url = firstTarget else { return }
        meta = ExifEditor.read(from: url)
        original = meta
        camera = ExifEditor.readCameraInfo(from: url)
        keywordsText = meta.keywords.joined(separator: ", ")
        if let loc = meta.location {
            hasLocation = true
            latText = String(loc.latitude)
            lonText = String(loc.longitude)
        } else {
            hasLocation = false
            latText = ""; lonText = ""
        }
        altText = meta.altitude.map { String($0) } ?? ""
        errorMessage = nil
    }

    private func save() {
        saving = true
        errorMessage = nil
        let snapshot = meta
        let originalSnapshot = original
        let urls = targets
        let batch = isBatch
        Task.detached(priority: .userInitiated) {
            var firstError: String?
            for url in urls {
                do {
                    let toWrite: EditableMetadata
                    if batch {
                        // In batch mode, only overwrite fields the user
                        // actually changed in the editor (vs. originals
                        // loaded from the *first* file).
                        toWrite = mergeForBatch(
                            edited: snapshot,
                            base: ExifEditor.read(from: url),
                            original: originalSnapshot
                        )
                    } else {
                        toWrite = snapshot
                    }
                    try ExifEditor.write(toWrite, from: url, to: url)
                } catch {
                    firstError = error.localizedDescription
                    break
                }
            }
            await MainActor.run {
                saving = false
                if let firstError {
                    errorMessage = firstError
                } else {
                    close()
                }
            }
        }
    }

    private func close() {
        onClose()
        dismiss()
    }
}

/// In batch mode, apply only fields the user explicitly modified.
/// Each per-file write starts from that file's existing metadata and
/// overlays just the changed fields from the editor.
private func mergeForBatch(
    edited: EditableMetadata,
    base: EditableMetadata,
    original: EditableMetadata
) -> EditableMetadata {
    var out = base
    if edited.imageDescription != original.imageDescription { out.imageDescription = edited.imageDescription }
    if edited.artist != original.artist { out.artist = edited.artist }
    if edited.copyright != original.copyright { out.copyright = edited.copyright }
    if edited.software != original.software { out.software = edited.software }
    if edited.userComment != original.userComment { out.userComment = edited.userComment }
    if edited.dateTimeOriginal != original.dateTimeOriginal { out.dateTimeOriginal = edited.dateTimeOriginal }
    if edited.keywords != original.keywords { out.keywords = edited.keywords }
    if edited.rating != original.rating { out.rating = edited.rating }
    if edited.location?.latitude != original.location?.latitude
        || edited.location?.longitude != original.location?.longitude {
        out.location = edited.location
        out.altitude = edited.altitude
    }
    return out
}
