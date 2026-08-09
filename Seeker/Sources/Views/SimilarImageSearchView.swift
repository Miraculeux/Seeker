import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SimilarImageSearchRequest: Codable, Hashable {
    let referenceURL: URL
    let targetDirectory: URL
}

struct SimilarImageSearchView: View {
    private struct ScoredResult: Identifiable {
        let url: URL
        let match: SimilarImageFinder.Match
        var id: URL { url }
    }

    enum Status: Equatable {
        case ready
        case comparing(total: Int)
        case done
        case failed(String)
    }

    let referenceURL: URL
    @State private var targetDirectory: URL
    @State private var status: Status = .ready
    @State private var scoredResults: [ScoredResult] = []
    @State private var excludedURLs: Set<URL> = []
    @State private var minimumSimilarity = 0.65
    @State private var workTask: Task<Void, Never>?
    @State private var useSemanticModel: Bool
    @State private var semanticModelID: String
    @State private var modelManager = SemanticModelManager.shared
    @State private var downloadSource = SettingsManager.shared.semanticDownloadSource
    @State private var customDownloadURL = SettingsManager.shared.semanticCustomDownloadURL

    init(request: SimilarImageSearchRequest) {
        referenceURL = request.referenceURL
        _targetDirectory = State(initialValue: request.targetDirectory)
        _useSemanticModel = State(initialValue: SettingsManager.shared.useSemanticImageComparison)
        let savedModel = SemanticModelDescriptor.model(id: SettingsManager.shared.imageComparisonModelID)
        _semanticModelID = State(initialValue:
            savedModel.availability == .downloadable
                ? savedModel.id
                : SemanticModelDescriptor.defaultComparisonModel.id
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            comparisonBar
            Divider()
            resultContent
        }
        .frame(minWidth: 860, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .onDisappear { workTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: referenceURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Find Visually Similar Images")
                    .font(.system(size: 14, weight: .semibold))
                Text("Reference: \(referenceURL.lastPathComponent)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(referenceURL.path)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }

    private var comparisonBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Target Folder")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                Text(targetDirectory.path)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(targetDirectory.path)
            }
            Spacer(minLength: 12)
            Button("Choose Folder...") { chooseTargetDirectory() }
            Toggle("AI", isOn: $useSemanticModel)
                .toggleStyle(.checkbox)
                .onChange(of: useSemanticModel) { _, value in
                    SettingsManager.shared.useSemanticImageComparison = value
                }
                .help("Include semantic similarity from the selected Core ML model")
            if useSemanticModel {
                Picker("", selection: $semanticModelID) {
                    ForEach(SemanticModelDescriptor.all.filter { $0.availability == .downloadable }) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .onChange(of: semanticModelID) { _, value in
                    SettingsManager.shared.imageComparisonModelID = value
                }
                if !modelManager.isInstalled(selectedSemanticModel),
                   selectedSemanticModel.availability == .downloadable {
                    Picker("", selection: $downloadSource) {
                        ForEach(SemanticModelDownloadSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .onChange(of: downloadSource) { _, value in
                        SettingsManager.shared.semanticDownloadSource = value
                    }
                    if downloadSource == .custom {
                        TextField("Mirror URL", text: $customDownloadURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .onChange(of: customDownloadURL) { _, value in
                                SettingsManager.shared.semanticCustomDownloadURL = value
                            }
                    }
                    if modelManager.activeModelID == selectedSemanticModel.id {
                        switch modelManager.state {
                        case .downloading, .compiling:
                            ProgressView().controlSize(.small)
                            Button("Cancel") { modelManager.cancelInstall() }
                        case .failed(let message):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .help(message)
                            downloadButton
                        default:
                            downloadButton
                        }
                    } else {
                        downloadButton
                    }
                }
            }
            Button {
                compare()
            } label: {
                Label(status == .done ? "Find Again" : "Find", systemImage: "photo.stack")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isComparing || !semanticModelIsReady)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var resultContent: some View {
        switch status {
        case .ready:
            placeholder(
                icon: "photo.on.rectangle.angled",
                title: "Choose a target folder, then compare",
                detail: "Images directly inside the folder will be ranked by visual similarity."
            )
        case .comparing(let total):
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 300)
                Text(total > 0 ? "Comparing \(total) images" : "Finding images")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Button("Cancel") { cancelComparison() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            if scoredResults.isEmpty {
                placeholder(
                    icon: "photo.badge.exclamationmark",
                    title: "No comparable images found",
                    detail: "The target folder contains no other images Vision could analyze."
                )
            } else {
                TriageExplorerPanel(
                    fixedURLs: filteredResults.map(\.url),
                    emptyMessage: "No images meet the threshold",
                    subtitles: scoreSubtitles,
                    allowsIconView: true,
                    usesFloatingQuickLook: true,
                    similarityThreshold: $minimumSimilarity,
                    similarityTotalCount: scoredResults.count,
                    footerStatusText: "\(filteredResults.count) images, most similar first",
                    onDeleted: removeResult
                )
            }
        case .failed(let message):
            placeholder(icon: "exclamationmark.triangle", title: "Comparison failed", detail: message)
        }
    }

    private var filteredResults: [ScoredResult] {
        scoredResults.filter {
            Double($0.match.similarity) >= minimumSimilarity
                && !excludedURLs.contains($0.url)
        }
    }

    private var scoreSubtitles: [URL: String] {
        Dictionary(uniqueKeysWithValues: filteredResults.map { result in
            let match = result.match
            return (result.url, String(
                format: "%.0f%% · Vision %.0f%% · pHash %.0f%% · Shape %.0f%%",
                match.similarity * 100,
                match.visionSimilarity * 100,
                match.pHashSimilarity * 100,
                match.aspectSimilarity * 100
            ) + (match.semanticSimilarity.map {
                String(format: " · AI %.0f%%", $0 * 100)
            } ?? ""))
        })
    }

    private var selectedSemanticModel: SemanticModelDescriptor {
        SemanticModelDescriptor.model(id: semanticModelID)
    }

    private var semanticModelIsReady: Bool {
        !useSemanticModel || modelManager.isInstalled(selectedSemanticModel)
    }

    private var downloadButton: some View {
        Button("Download") {
            modelManager.install(
                selectedSemanticModel,
                source: downloadSource,
                customURL: customDownloadURL
            )
        }
    }

    private var isComparing: Bool {
        if case .comparing = status { return true }
        return false
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseTargetDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = targetDirectory
        panel.prompt = "Choose"
        panel.message = "Choose the folder whose images you want to compare"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cancelComparison()
        targetDirectory = url
        scoredResults = []
        excludedURLs = []
        status = .ready
    }

    private func compare() {
        cancelComparison()
        scoredResults = []
        excludedURLs = []
        status = .comparing(total: 0)
        let reference = referenceURL
        let directory = targetDirectory
        let useSemantic = useSemanticModel
        let model = selectedSemanticModel

        workTask = Task {
            let scanTask = Task.detached(priority: .userInitiated) {
                Self.imageCandidates(in: directory)
            }
            let candidates = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled else { return }
            guard !candidates.isEmpty else {
                status = .done
                return
            }
            status = .comparing(total: candidates.count)
            do {
                let comparisonTask = Task.detached(priority: .userInitiated) {
                    let session = useSemantic ? try SemanticModelSession(descriptor: model) : nil
                    return try await SimilarImageFinder.findSimilar(
                        to: reference,
                        among: candidates,
                        semanticSession: session
                    )
                }
                let matches = try await withTaskCancellationHandler {
                    try await comparisonTask.value
                } onCancel: {
                    comparisonTask.cancel()
                }
                guard !Task.isCancelled else { return }
                let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.url) })
                scoredResults = matches.compactMap { match in
                    guard let url = candidateByID[match.id] else { return nil }
                    return ScoredResult(url: url, match: match)
                }
                status = .done
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed(error.localizedDescription)
            }
            workTask = nil
        }
    }

    private func cancelComparison() {
        workTask?.cancel()
        workTask = nil
        if isComparing { status = .ready }
    }

    private func removeResult(_ url: URL) {
        excludedURLs.insert(url)
    }

    private nonisolated static func imageCandidates(in directory: URL) -> [SimilarImageCandidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.contentType?.conforms(to: .image) == true else { return nil }
            return SimilarImageCandidate(id: url.absoluteString, url: url)
        }
    }
}
