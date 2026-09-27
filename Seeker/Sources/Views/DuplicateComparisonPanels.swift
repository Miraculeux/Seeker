import SwiftUI

struct DuplicateComparisonTargets: Equatable {
    let selected: URL?
    let copies: [URL]

    init(selected: URL?, groups: [DuplicateFinder.Group]) {
        guard let selected, let group = groups.first(where: {
            $0.urls.contains { $0.standardizedFileURL == selected.standardizedFileURL }
        }) else {
            self.selected = nil
            copies = []
            return
        }
        self.selected = selected
        var seen: Set<URL> = [selected.standardizedFileURL]
        copies = group.urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    func comparison(preferred: URL?) -> URL? {
        if let preferred, let match = copies.first(where: {
            $0.standardizedFileURL == preferred.standardizedFileURL
        }) {
            return match
        }
        return copies.first
    }
}

struct DuplicateComparisonPanels: View {
    let targets: DuplicateComparisonTargets
    let onDeleted: (URL) -> Void
    @State private var preferredCopy: URL?

    var body: some View {
        let copy = targets.comparison(preferred: preferredCopy)
        VSplitView {
            VStack(spacing: 0) {
                panelHeader("Selected File")
                if let selected = targets.selected {
                    TriageExplorerPanel(targetURL: selected, onDeleted: onDeleted)
                } else {
                    placeholder("Select a file in the duplicate results")
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Identical Copy")
                        .font(.system(size: 11, weight: .semibold))
                    if let copy {
                        Picker("Identical copy", selection: Binding(
                            get: { copy },
                            set: { preferredCopy = $0 }
                        )) {
                            ForEach(targets.copies, id: \.self) { url in
                                Text(url.path).tag(url)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .help(copy.path)
                        .frame(maxWidth: .infinity)
                    } else {
                        Spacer()
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.primary.opacity(0.04))
                Divider()
                if let copy {
                    TriageExplorerPanel(
                        targetURL: copy,
                        focusesOnTargetChange: false,
                        onDeleted: onDeleted
                    )
                } else {
                    placeholder("No other identical copy")
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)
        }
        .onChange(of: targets) { _, newTargets in
            preferredCopy = newTargets.comparison(preferred: preferredCopy)
        }
    }

    private func panelHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.primary.opacity(0.04))
            Divider()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
