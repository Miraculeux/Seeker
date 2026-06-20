import SwiftUI
import AppKit

/// Sheet that batch-renames a set of files. Three modes (find/replace,
/// numbered sequence, EXIF-date) with a live preview of old → new names.
/// On confirm it applies the renames and reports the resulting `(old,
/// new)` pairs via `onComplete` so the host can refresh and offer undo.
struct BatchRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var renamer: BatchRenamer
    @State private var previews: [BatchRenamer.Preview] = []
    @State private var isApplying = false

    /// Called after a successful apply with the renamed pairs.
    let onComplete: ([(from: URL, to: URL)]) -> Void

    init(urls: [URL], onComplete: @escaping ([(from: URL, to: URL)]) -> Void) {
        _renamer = State(initialValue: BatchRenamer(urls: urls))
        self.onComplete = onComplete
    }

    private static let datePresets = ["yyyy-MM-dd", "yyMMdd", "yyyyMMdd", "yyyy-MM-dd_HHmmss"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modePicker
            Divider()
            options
                .padding(14)
            Divider()
            previewList
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .onAppear { refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Batch Rename")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(renamer.urls.count) item\(renamer.urls.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }

    private var modePicker: some View {
        Picker("", selection: Binding(
            get: { renamer.mode },
            set: { renamer.mode = $0; refresh() }
        )) {
            ForEach(BatchRenamer.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Options per mode

    @ViewBuilder
    private var options: some View {
        switch renamer.mode {
        case .findReplace: findReplaceOptions
        case .sequence: sequenceOptions
        case .exifDate: exifOptions
        }
    }

    private var findReplaceOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledField("Find", text: Binding(
                get: { renamer.find }, set: { renamer.find = $0; refresh() }
            ), placeholder: renamer.useRegex ? "regular expression" : "text to find")
            labeledField("Replace", text: Binding(
                get: { renamer.replacement }, set: { renamer.replacement = $0; refresh() }
            ), placeholder: "replacement")
            HStack(spacing: 16) {
                Toggle("Ignore case", isOn: Binding(
                    get: { renamer.ignoreCase }, set: { renamer.ignoreCase = $0; refresh() }
                ))
                Toggle("Regular expression", isOn: Binding(
                    get: { renamer.useRegex }, set: { renamer.useRegex = $0; refresh() }
                ))
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
        }
    }

    private var sequenceOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledField("Prefix", text: Binding(
                get: { renamer.prefix }, set: { renamer.prefix = $0; refresh() }
            ), placeholder: "optional")
            labeledField("Suffix", text: Binding(
                get: { renamer.suffix }, set: { renamer.suffix = $0; refresh() }
            ), placeholder: "optional (before extension)")
            HStack(spacing: 8) {
                Text("Start at")
                    .font(.system(size: 11))
                    .frame(width: 70, alignment: .trailing)
                Stepper(value: Binding(
                    get: { renamer.startNumber },
                    set: { renamer.startNumber = max(0, $0); refresh() }
                ), in: 0...1_000_000) {
                    Text("\(renamer.startNumber)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                Text("Numbers are zero-padded to the same width.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var exifOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Date format")
                    .font(.system(size: 11))
                    .frame(width: 90, alignment: .trailing)
                TextField("yyyy-MM-dd", text: Binding(
                    get: { renamer.dateFormat }, set: { renamer.dateFormat = $0; refresh() }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(maxWidth: 180)
            }
            HStack(spacing: 6) {
                Spacer().frame(width: 90)
                ForEach(Self.datePresets, id: \.self) { preset in
                    Button(preset) { renamer.dateFormat = preset; refresh() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                }
            }
            HStack(spacing: 8) {
                Text("Separator")
                    .font(.system(size: 11))
                    .frame(width: 90, alignment: .trailing)
                Toggle("", isOn: Binding(
                    get: { renamer.useSeparator }, set: { renamer.useSeparator = $0; refresh() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                TextField("-", text: Binding(
                    get: { renamer.separator }, set: { renamer.separator = $0; refresh() }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 50)
                .disabled(!renamer.useSeparator)
                Text("date \(renamer.useSeparator ? renamer.separator : "")sequence")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Text("Start at")
                    .font(.system(size: 11))
                    .frame(width: 90, alignment: .trailing)
                Stepper(value: Binding(
                    get: { renamer.dateStartNumber },
                    set: { renamer.dateStartNumber = max(0, $0); refresh() }
                ), in: 0...1_000_000) {
                    Text("\(renamer.dateStartNumber)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                if renamer.isLoadingDates {
                    ProgressView().controlSize(.small)
                    Text("Reading dates\u{2026}")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Text("Date is read from the image's EXIF capture time, or the file's creation date if there is no EXIF.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 70, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }

    // MARK: - Preview

    private var previewList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(previews) { row in
                    HStack(spacing: 8) {
                        Text(row.oldName)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                        Group {
                            if let error = row.error {
                                Text(error)
                                    .foregroundColor(.red)
                            } else {
                                Text(row.newName)
                                    .foregroundColor(row.changed ? .primary : .secondary)
                                    .fontWeight(row.changed ? .medium : .regular)
                            }
                        }
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isApplying ? "Renaming\u{2026}" : "Rename") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || !renamer.canApply(previews))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let changed = previews.filter { $0.changed }.count
        let errors = previews.filter { $0.error != nil }.count
        if errors > 0 {
            return "\(changed) to rename \u{00B7} \(errors) problem\(errors == 1 ? "" : "s")"
        }
        return "\(changed) of \(previews.count) will be renamed"
    }

    // MARK: - Actions

    private func refresh() {
        if renamer.mode == .exifDate {
            Task {
                await renamer.loadDatesIfNeeded()
                previews = renamer.previews()
            }
        }
        previews = renamer.previews()
    }

    private func apply() {
        isApplying = true
        Task {
            let result = await renamer.apply()
            isApplying = false
            if !result.errors.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Some files could not be renamed"
                alert.informativeText = result.errors.prefix(10).joined(separator: "\n")
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            if !result.renamed.isEmpty {
                onComplete(result.renamed)
            }
            dismiss()
        }
    }
}
