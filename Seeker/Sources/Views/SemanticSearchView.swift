import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Vision

struct SemanticSearchRequest: Codable, Hashable {
    let targetDirectory: URL
}

struct SemanticSearchView: View {
    private struct Result: Identifiable {
        let url: URL
        let similarity: Float
        let semanticSimilarity: Float
        let visionMatched: Bool
        let ocrMatched: Bool
        let relevance: Float
        var id: URL { url }
    }

    private enum Status: Equatable {
        case ready
        case searching(total: Int)
        case done
        case failed(String)
    }

    @State private var targetDirectory: URL
    @State private var query = ""
    @State private var modelID: String = {
        let saved = SemanticModelDescriptor.model(id: SettingsManager.shared.semanticSearchModelID)
        return saved.availability == .downloadable ? saved.id : SemanticModelDescriptor.defaultSearchModel.id
    }()
    @State private var status: Status = .ready
    @State private var results: [Result] = []
    @State private var excludedURLs: Set<URL> = []
    @State private var searchTask: Task<Void, Never>?
    @State private var modelManager = SemanticModelManager.shared
    @State private var downloadSource = SettingsManager.shared.semanticDownloadSource
    @State private var customDownloadURL = SettingsManager.shared.semanticCustomDownloadURL
    @State private var searchesSubfolders = SettingsManager.shared.semanticSearchSubfolders
    @State private var usesOCR = SettingsManager.shared.semanticSearchOCR
    @State private var minimumRelevance = SettingsManager.shared.semanticSearchMinimumRelevance
    @State private var resultLimit = SettingsManager.shared.semanticSearchResultLimit

    init(request: SemanticSearchRequest) {
        _targetDirectory = State(initialValue: request.targetDirectory)
    }

    private var selectedModel: SemanticModelDescriptor {
        SemanticModelDescriptor.model(id: modelID)
    }

    private var visibleResults: [Result] {
        Array(results.lazy.filter {
            !excludedURLs.contains($0.url) && $0.relevance >= Float(minimumRelevance)
        }.prefix(resultLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            optionsBar
            Divider()
            content
        }
        .frame(minWidth: 860, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .onDisappear { searchTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "brain")
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Semantic Search")
                    .font(.system(size: 14, weight: .semibold))
                Text("Find images by natural-language meaning")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Describe the image to find", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { search() }
            Button {
                chooseDirectory()
            } label: {
                Label(targetDirectory.lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
            }
            .help(targetDirectory.path)
            Picker("", selection: $modelID) {
                ForEach(SemanticModelDescriptor.all.filter { $0.availability == .downloadable }) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            .onChange(of: modelID) { _, value in
                SettingsManager.shared.semanticSearchModelID = value
            }
            if !modelManager.isInstalled(selectedModel),
               selectedModel.availability == .downloadable {
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
                Button("Download") {
                    modelManager.install(
                        selectedModel,
                        source: downloadSource,
                        customURL: customDownloadURL
                    )
                }
            }
            Button("Find") { search() }
                .buttonStyle(.borderedProminent)
                .disabled(
                    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !modelManager.isInstalled(selectedModel)
                        || isSearching
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.02))
    }

    private var optionsBar: some View {
        HStack(spacing: 12) {
            Toggle("Subfolders", isOn: $searchesSubfolders)
                .toggleStyle(.checkbox)
                .onChange(of: searchesSubfolders) { _, value in
                    SettingsManager.shared.semanticSearchSubfolders = value
                }
            Toggle("OCR", isOn: $usesOCR)
                .toggleStyle(.checkbox)
                .onChange(of: usesOCR) { _, value in
                    SettingsManager.shared.semanticSearchOCR = value
                }
                .help("Include text recognized inside screenshots and documents")
            Divider().frame(height: 16)
            Text("Minimum relevance")
                .font(.system(size: 10, weight: .medium))
            Slider(value: $minimumRelevance, in: 0.25...0.95, step: 0.05)
                .controlSize(.mini)
                .frame(width: 150)
                .onChange(of: minimumRelevance) { _, value in
                    SettingsManager.shared.semanticSearchMinimumRelevance = value
                }
            Text("\(Int((minimumRelevance * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
            Picker("Top", selection: $resultLimit) {
                ForEach([10, 25, 50, 100], id: \.self) { Text("Top \($0)").tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 80)
            .onChange(of: resultLimit) { _, value in
                SettingsManager.shared.semanticSearchResultLimit = value
            }
            if case .done = status {
                Text("\(visibleResults.count) of \(results.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.015))
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .ready:
            if case .downloading(let progress, let file) = modelManager.state {
                progressView(title: "Downloading \(file)", progress: progress, canCancelModelInstall: true)
            } else if case .compiling = modelManager.state {
                progressView(title: "Compiling Core ML model", progress: nil, canCancelModelInstall: true)
            } else if case .failed(let message) = modelManager.state {
                placeholder(icon: "exclamationmark.triangle", title: "Model download failed", detail: message)
            } else {
                placeholder(
                    icon: "text.magnifyingglass",
                    title: "Search by meaning",
                    detail: "Try descriptions such as “jasmine flowers”, “a dog running”, or “海边日落”. English queries work best with MobileCLIP."
                )
            }
        case .searching(let total):
            progressView(title: "Analyzing \(total) images", progress: nil)
        case .done:
            if visibleResults.isEmpty {
                placeholder(icon: "photo.badge.exclamationmark", title: "No images found", detail: "Try a broader description or another folder.")
            } else {
                TriageExplorerPanel(
                    fixedURLs: visibleResults.map(\.url),
                    emptyMessage: "No images found",
                    subtitles: Dictionary(uniqueKeysWithValues: visibleResults.map {
                        let vision = $0.visionMatched ? " · Vision person match" : ""
                        let ocr = $0.ocrMatched ? " · OCR match" : ""
                        return ($0.url, String(format: "Relevance %.0f%%%@%@", $0.relevance * 100, vision, ocr))
                    }),
                    allowsIconView: true,
                    usesFloatingQuickLook: true,
                    footerStatusText: "\(visibleResults.count) images, best semantic match first",
                    onDeleted: { excludedURLs.insert($0) }
                )
            }
        case .failed(let message):
            placeholder(icon: "exclamationmark.triangle", title: "Search failed", detail: message)
        }
    }

    private var isSearching: Bool {
        if case .searching = status { return true }
        return false
    }

    private func progressView(
        title: String,
        progress: Double?,
        canCancelModelInstall: Bool = false
    ) -> some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress).frame(width: 300)
            } else {
                ProgressView().progressViewStyle(.linear).frame(width: 300)
            }
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            if isSearching {
                Button("Cancel") { cancelSearch() }
            } else if canCancelModelInstall {
                Button("Cancel") { modelManager.cancelInstall() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = targetDirectory
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cancelSearch()
        targetDirectory = url
        results = []
        excludedURLs = []
        status = .ready
    }

    private func search() {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, modelManager.isInstalled(selectedModel) else { return }
        cancelSearch()
        results = []
        excludedURLs = []
        status = .searching(total: 0)
        let directory = targetDirectory
        let model = selectedModel
        let recursive = searchesSubfolders
        let includeOCR = usesOCR

        searchTask = Task {
            let scanTask = Task.detached(priority: .userInitiated) {
                Self.imageURLs(in: directory, recursive: recursive)
            }
            let urls = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled else { return }
            await SemanticSearchCache.shared.pruneMissingEntries(maxChecks: 500)
            status = .searching(total: urls.count)
            do {
                let rankingTask = Task.detached(priority: .userInitiated) {
                    let session = try SemanticModelSession(descriptor: model)
                    let prompts = Self.expandedPrompts(for: trimmedQuery)
                    let queryEmbedding = try Self.averageNormalizedEmbeddings(
                        prompts.map { try session.textEmbedding(for: $0) }
                    )
                    return try await Self.rankImages(
                        urls,
                        queryEmbedding: queryEmbedding,
                        session: session,
                        modelID: model.cacheNamespace,
                        query: trimmedQuery,
                        personIntent: Self.isPersonQuery(trimmedQuery),
                        includeOCR: includeOCR
                    )
                }
                let found = try await withTaskCancellationHandler {
                    try await rankingTask.value
                } onCancel: {
                    rankingTask.cancel()
                }
                guard !Task.isCancelled else { return }
                results = found
                status = .done
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed(error.localizedDescription)
            }
            searchTask = nil
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        if isSearching { status = .ready }
    }

    private nonisolated static func rankImages(
        _ urls: [URL],
        queryEmbedding: [Float],
        session: SemanticModelSession,
        modelID: String,
        query: String,
        personIntent: Bool,
        includeOCR: Bool
    ) async throws -> [Result] {
        let workerCount = min(4, urls.count)
        guard workerCount > 0 else { return [] }
        return await withTaskGroup(of: [Result].self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    var matches: [Result] = []
                    for index in stride(from: worker, to: urls.count, by: workerCount) {
                        if Task.isCancelled { break }
                        let url = urls[index]
                        let cached = await SemanticSearchCache.shared.embedding(for: url, modelID: modelID)
                        guard let embedding = cached ?? (try? session.imageEmbedding(for: url)) else { continue }
                        if cached == nil {
                            await SemanticSearchCache.shared.store(embedding: embedding, for: url, modelID: modelID)
                        }
                        if Task.isCancelled { break }
                        let semantic = SemanticModelSession.cosineSimilarity(queryEmbedding, embedding)
                        let visionMatched = personIntent && Self.containsPerson(in: url)
                        if Task.isCancelled { break }
                        let ocrMatched: Bool
                        if includeOCR {
                            let cachedText = await SemanticSearchCache.shared.recognizedText(for: url)
                            let freshText = cachedText == nil ? Self.recognizedText(in: url) : nil
                            let text = cachedText ?? freshText ?? ""
                            if cachedText == nil, let freshText {
                                await SemanticSearchCache.shared.store(recognizedText: freshText, for: url)
                            }
                            ocrMatched = Self.text(text, matches: query)
                        } else {
                            ocrMatched = false
                        }
                        let score = semantic + (visionMatched ? 0.15 : 0) + (ocrMatched ? 0.20 : 0)
                        matches.append(Result(
                            url: url,
                            similarity: score,
                            semanticSimilarity: semantic,
                            visionMatched: visionMatched,
                            ocrMatched: ocrMatched,
                            relevance: 0
                        ))
                    }
                    return matches
                }
            }
            var combined: [Result] = []
            for await matches in group { combined.append(contentsOf: matches) }
            let sorted = combined.sorted { $0.similarity > $1.similarity }
            guard !sorted.isEmpty else { return [] }
            let best = sorted[0].similarity
            return sorted.map { result in
                Result(
                    url: result.url,
                    similarity: result.similarity,
                    semanticSimilarity: result.semanticSimilarity,
                    visionMatched: result.visionMatched,
                    ocrMatched: result.ocrMatched,
                    relevance: exp((result.similarity - best) * 8)
                )
            }
        }
    }

    private nonisolated static func expandedPrompts(for query: String) -> [String] {
        if isPersonQuery(query) {
            return [
                query,
                "含有一个或多个人物的照片",
                "有人脸或人体出现的图片",
                "a photo containing one or more people",
                "a photo of a person with a visible face or body"
            ]
        }
        return [
            query,
            "这是一张\(query)的图片",
            "包含\(query)的照片",
            "a photo of \(query)",
            "an image containing \(query)"
        ]
    }

    private nonisolated static func averageNormalizedEmbeddings(
        _ embeddings: [[Float]]
    ) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var average = [Float](repeating: 0, count: first.count)
        for embedding in embeddings where embedding.count == average.count {
            let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { continue }
            for index in average.indices { average[index] += embedding[index] / norm }
        }
        let norm = sqrt(average.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? average.map { $0 / norm } : average
    }

    private nonisolated static func isPersonQuery(_ query: String) -> Bool {
        let value = query.lowercased()
        let terms = [
            "人物", "人像", "人脸", "有人", "人类", "男生", "女生", "男人", "女人",
            "person", "people", "human", "portrait", "face", "man", "woman", "girl", "boy"
        ]
        return terms.contains { value.contains($0) }
    }

    private nonisolated static func containsPerson(in url: URL) -> Bool {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false
        let handler = VNImageRequestHandler(url: url)
        try? handler.perform([faceRequest, humanRequest])
        return !(faceRequest.results?.isEmpty ?? true)
            || !(humanRequest.results?.isEmpty ?? true)
    }

    private nonisolated static func recognizedText(in url: URL) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        do {
            try VNImageRequestHandler(url: url).perform([request])
            return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        } catch {
            return nil
        }
    }

    private nonisolated static func text(_ recognized: String, matches query: String) -> Bool {
        let normalizedText = recognized.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var searchableQuery = query
        let stopPhrases = [
            "图片", "照片", "查找", "寻找", "包含", "含有", "文字", "文本", "截图", "文档",
            "里面", "中的", "的", "image", "photo", "find", "containing", "contains", "text", "screenshot", "document"
        ]
        for phrase in stopPhrases {
            searchableQuery = searchableQuery.replacingOccurrences(
                of: phrase,
                with: " ",
                options: .caseInsensitive
            )
        }
        let terms = searchableQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        return !terms.isEmpty && terms.allSatisfy { normalizedText.localizedCaseInsensitiveContains($0) }
    }

    private nonisolated static func imageURLs(in directory: URL, recursive: Bool) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { return [] }
            var images: [URL] = []
            for case let url as URL in enumerator {
                if Task.isCancelled { break }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      values.contentType?.conforms(to: .image) == true else { continue }
                images.append(url)
            }
            return images
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter {
            guard let values = try? $0.resourceValues(forKeys: keys) else { return false }
            return values.isRegularFile == true && values.contentType?.conforms(to: .image) == true
        }
    }
}
