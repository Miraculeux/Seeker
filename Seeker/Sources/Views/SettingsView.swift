import SwiftUI

struct SettingsView: View {
    @State private var rememberLastLocation: Bool = SettingsManager.shared.rememberLastLocation

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
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 180)
        .scrollDisabled(true)
    }
}
