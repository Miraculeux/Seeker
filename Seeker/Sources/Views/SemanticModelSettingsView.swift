import SwiftUI
import AppKit

struct SemanticModelSettingsView: View {
    @State private var selectedModelID = SettingsManager.shared.semanticSearchModelID
    @State private var searchModelID = SettingsManager.shared.semanticSearchModelID
    @State private var comparisonModelID = SettingsManager.shared.imageComparisonModelID
    @State private var source = SettingsManager.shared.semanticDownloadSource
    @State private var customURL = SettingsManager.shared.semanticCustomDownloadURL
    @State private var storagePath = SettingsManager.shared.semanticModelStoragePath
    @State private var manager = SemanticModelManager.shared
    @State private var semanticCacheBytes: Int64 = 0
    @State private var isClearingSemanticCache = false

    private var selectedModel: SemanticModelDescriptor {
        SemanticModelDescriptor.model(id: selectedModelID)
    }

    private var storageURL: URL {
        storagePath.isEmpty
            ? SemanticModelStorage.defaultRootDirectory
            : URL(fileURLWithPath: storagePath, isDirectory: true).standardizedFileURL
    }

    var body: some View {
        Form {
            Section("Default Models") {
                Picker("Semantic Search", selection: $searchModelID) {
                    ForEach(SemanticModelDescriptor.all) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .onChange(of: searchModelID) { _, value in
                    SettingsManager.shared.semanticSearchModelID = value
                }
                Picker("Image Comparison", selection: $comparisonModelID) {
                    ForEach(SemanticModelDescriptor.all) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .onChange(of: comparisonModelID) { _, value in
                    SettingsManager.shared.imageComparisonModelID = value
                }
                Text("SigLIP 2 is recommended for Chinese and multilingual text search. MobileCLIP-S2 is faster for optional image-comparison scoring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Download Source") {
                Picker("Source", selection: $source) {
                    ForEach(SemanticModelDownloadSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .onChange(of: source) { _, value in
                    SettingsManager.shared.semanticDownloadSource = value
                }

                if source == .custom {
                    TextField("Mirror base URL", text: $customURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: customURL) { _, value in
                            SettingsManager.shared.semanticCustomDownloadURL = value
                        }
                    Text("The mirror must expose the same relative paths as apple/coreml-mobileclip and the CLIP tokenizer files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if source == .modelScope {
                    Text("MobileCLIP model files use ModelScope. Tokenizer files and SigLIP 2 fall back to Hugging Face when no matching ModelScope Core ML mirror exists.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Model Storage") {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .foregroundStyle(.secondary)
                    Text(storageURL.path)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(storageURL.path)
                    Spacer()
                    Button("Choose Folder...") { chooseStorageFolder() }
                }
                HStack {
                    Text(storagePath.isEmpty ? "Using the default Application Support location." : "Using a custom model location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task {
                            semanticCacheBytes = await SemanticSearchCache.shared.currentSizeBytes()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh cache size")
                    Button("Reveal") {
                        NSWorkspace.shared.open(storageURL)
                    }
                    .disabled(!FileManager.default.fileExists(atPath: storageURL.path))
                    Button("Use Default") { resetStorageFolder() }
                        .disabled(storagePath.isEmpty)
                }
                Text("Changing this location does not move or delete models in the previous folder. Models already present in the selected folder are detected automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Installed Model") {
                Picker("Manage", selection: $selectedModelID) {
                    ForEach(SemanticModelDescriptor.all) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedModel.displayName)
                        modelStateText
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    modelAction
                }

                if case .downloading(let progress, let file) = manager.state {
                    ProgressView(value: progress)
                    Text("Downloading \(file)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .compiling = manager.state {
                    ProgressView()
                    Text("Compiling Core ML models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .failed(let message) = manager.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Search Cache") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Image embeddings and recognized text")
                        Text(ByteCountFormatter.string(fromByteCount: semanticCacheBytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            SemanticSearchCache.shared.databaseURL
                        ])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: SemanticSearchCache.shared.databaseURL.path))
                    Button("Clear") {
                        isClearingSemanticCache = true
                        Task {
                            await SemanticSearchCache.shared.removeAll()
                            semanticCacheBytes = await SemanticSearchCache.shared.currentSizeBytes()
                            isClearingSemanticCache = false
                        }
                    }
                    .disabled(isClearingSemanticCache || semanticCacheBytes == 0)
                }
                Text("Cached entries are keyed by model, file size, and modification date. Changed files and model switches are reprocessed automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Models run locally with Core ML and are not uploaded by Seeker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .task {
            semanticCacheBytes = await SemanticSearchCache.shared.currentSizeBytes()
        }
    }

    @ViewBuilder
    private var modelStateText: some View {
        if selectedModel.availability == .planned {
            Text("Not yet available")
        } else if manager.isInstalled(selectedModel) {
            Text("Installed")
        } else if selectedModel.id == SemanticModelDescriptor.sigLIP2Base.id {
            Text("About 356 MB")
        } else {
            Text("About 200 MB")
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        if selectedModel.availability == .planned {
            Button("Unavailable") {}
                .disabled(true)
        } else if manager.isInstalled(selectedModel) {
            Button("Remove", role: .destructive) {
                try? manager.remove(selectedModel)
            }
        } else if case .downloading = manager.state {
            Button("Cancel") { manager.cancelInstall() }
        } else if case .compiling = manager.state {
            Button("Working...") {}
                .disabled(true)
        } else {
            Button("Download") {
                manager.install(selectedModel, source: source, customURL: customURL)
            }
        }
    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = storageURL
        panel.prompt = "Choose"
        panel.message = "Choose where Seeker stores downloaded semantic models"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard path != storageURL.standardizedFileURL.path else { return }
        storagePath = path
        SettingsManager.shared.semanticModelStoragePath = path
        manager.storageLocationDidChange()
    }

    private func resetStorageFolder() {
        storagePath = ""
        SettingsManager.shared.semanticModelStoragePath = ""
        manager.storageLocationDidChange()
    }
}
