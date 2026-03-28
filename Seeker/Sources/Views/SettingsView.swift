import SwiftUI

struct SettingsView: View {
    @State private var rememberLastLocation: Bool = SettingsManager.shared.rememberLastLocation
    @State private var columns: [ColumnID] = SettingsManager.shared.columnOrder
    @State private var columnVisibility: [ColumnID: Bool] = {
        var vis: [ColumnID: Bool] = [:]
        for col in ColumnID.allCases {
            vis[col] = SettingsManager.shared.isColumnVisible(col)
        }
        return vis
    }()

    var body: some View {
        Form {
            Section("Navigation") {
                Toggle("Remember last opened locations", isOn: $rememberLastLocation)
                    .onChange(of: rememberLastLocation) { _, newValue in
                        SettingsManager.shared.rememberLastLocation = newValue
                    }
                Text("When enabled, Seeker will restore the folder locations of both explorer panels on next launch. If a saved path no longer exists, the home folder is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("List View Columns") {
                HStack {
                    Toggle("", isOn: .constant(true))
                        .labelsHidden()
                        .disabled(true)
                    Text("Name")
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(Array(columns.enumerated()), id: \.element) { index, col in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { columnVisibility[col] ?? true },
                            set: { newValue in
                                columnVisibility[col] = newValue
                                SettingsManager.shared.setColumnVisible(col, newValue)
                                NotificationCenter.default.post(name: .columnSettingsChanged, object: nil)
                            }
                        ))
                        .labelsHidden()
                        Text(col.label)
                        Spacer()
                        Button {
                            guard index > 0 else { return }
                            columns.swapAt(index, index - 1)
                            SettingsManager.shared.columnOrder = columns
                            NotificationCenter.default.post(name: .columnSettingsChanged, object: nil)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)

                        Button {
                            guard index < columns.count - 1 else { return }
                            columns.swapAt(index, index + 1)
                            SettingsManager.shared.columnOrder = columns
                            NotificationCenter.default.post(name: .columnSettingsChanged, object: nil)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == columns.count - 1)
                    }
                }

                Text("Use arrows to reorder columns. Name is always first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 420)
        .scrollDisabled(true)
    }
}
