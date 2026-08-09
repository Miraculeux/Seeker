import Foundation
import Observation
import CoreML
import CoreImage
import CryptoKit
import Vision

enum SemanticModelStorage {
    static let settingsKey = "semanticModelStoragePath"

    static var defaultRootDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.marvel.Seeker"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("SemanticModels", isDirectory: true)
    }

    static var rootDirectory: URL {
        guard let configured = UserDefaults.standard.string(forKey: settingsKey),
              !configured.isEmpty else { return defaultRootDirectory }
        return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
    }
}

@MainActor @Observable
final class SemanticModelManager {
    static let shared = SemanticModelManager()

    enum State: Equatable {
        case idle
        case downloading(progress: Double, file: String)
        case compiling
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var activeModelID: String?
    private(set) var storageRevision: UInt64 = 0
    private var downloadTask: Task<Void, Never>?

    func isInstalled(_ descriptor: SemanticModelDescriptor) -> Bool {
        _ = storageRevision
        return Self.isInstalled(descriptor)
    }

    func install(
        _ descriptor: SemanticModelDescriptor,
        source: SemanticModelDownloadSource,
        customURL: String
    ) {
        guard descriptor.availability == .downloadable, downloadTask == nil else { return }
        activeModelID = descriptor.id
        downloadTask = Task {
            do {
                try await installAndWait(descriptor, source: source, customURL: customURL)
                activeModelID = nil
            } catch is CancellationError {
                state = .idle
                activeModelID = nil
            } catch {
                state = .failed(error.localizedDescription)
            }
            downloadTask = nil
        }
    }

    func cancelInstall() {
        downloadTask?.cancel()
        downloadTask = nil
        activeModelID = nil
        state = .idle
    }

    func storageLocationDidChange() {
        cancelInstall()
        storageRevision &+= 1
    }

    func remove(_ descriptor: SemanticModelDescriptor) throws {
        cancelInstall()
        try? FileManager.default.removeItem(at: Self.modelDirectory(for: descriptor))
        state = .idle
    }

    func installAndWait(
        _ descriptor: SemanticModelDescriptor,
        source: SemanticModelDownloadSource,
        customURL: String
    ) async throws {
        let fm = FileManager.default
        let finalDirectory = Self.modelDirectory(for: descriptor)
        let stagingDirectory = finalDirectory.appendingPathExtension("downloading")
        try? fm.removeItem(at: stagingDirectory)
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDirectory) }

        for (index, asset) in descriptor.assets.enumerated() {
            try Task.checkCancellation()
            guard let baseURL = source.baseURL(customURL: customURL, origin: asset.origin) else {
                throw SemanticModelError.invalidDownloadURL
            }
            let remoteURL = baseURL.appendingPathComponent(asset.remotePath)
            state = .downloading(
                progress: Double(index) / Double(descriptor.assets.count),
                file: URL(fileURLWithPath: asset.localPath).lastPathComponent
            )
            let (temporaryURL, response) = try await Self.downloadWithResume(from: remoteURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw SemanticModelError.downloadFailed(remoteURL.absoluteString)
            }
            guard try Self.sha256(of: temporaryURL) == asset.sha256 else {
                throw SemanticModelError.checksumMismatch(asset.localPath)
            }
            let destination = stagingDirectory.appendingPathComponent(asset.localPath)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: temporaryURL, to: destination)
        }

        state = .compiling
        switch descriptor.packageFormat {
        case .sourcePackages:
            let imageCompiled = try await Self.compileModel(
                at: stagingDirectory.appendingPathComponent("image.mlpackage")
            )
            let textCompiled = try await Self.compileModel(
                at: stagingDirectory.appendingPathComponent("text.mlpackage")
            )
            try Task.checkCancellation()
            try fm.moveItem(at: imageCompiled, to: stagingDirectory.appendingPathComponent("image.mlmodelc"))
            try fm.moveItem(at: textCompiled, to: stagingDirectory.appendingPathComponent("text.mlmodelc"))
            try fm.removeItem(at: stagingDirectory.appendingPathComponent("image.mlpackage"))
            try fm.removeItem(at: stagingDirectory.appendingPathComponent("text.mlpackage"))
        case .compiledArchives:
            try await Self.installCompiledArchives(in: stagingDirectory)
        }
        try Data("installed".utf8).write(to: stagingDirectory.appendingPathComponent("complete"), options: .atomic)

        try? fm.removeItem(at: finalDirectory)
        try fm.moveItem(at: stagingDirectory, to: finalDirectory)
        state = .ready
    }

    private nonisolated static func compileModel(at url: URL) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) {
            try MLModel.compileModel(at: url)
        }
        return try await withTaskCancellationHandler {
            let compiled = try await task.value
            try Task.checkCancellation()
            return compiled
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func downloadWithResume(
        from url: URL,
        maximumAttempts: Int = 5
    ) async throws -> (URL, URLResponse) {
        var resumeData: Data?
        var lastError: Error?
        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            do {
                if let resumeData {
                    return try await URLSession.shared.download(resumeFrom: resumeData)
                }
                return try await URLSession.shared.download(from: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let nsError = error as NSError
                resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                lastError = error
                guard attempt < maximumAttempts else { break }
            }
        }
        throw lastError ?? SemanticModelError.downloadFailed(url.absoluteString)
    }

    private nonisolated static func installCompiledArchives(in directory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let archives = directory.appendingPathComponent("archives", isDirectory: true)
            let extraction = directory.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: extraction, withIntermediateDirectories: true)

            let jobs: [(archive: String, relativePath: String, destination: String)] = [
                ("ImageEncoder.mlmodelc.zip", "ImageEncoder.mlmodelc", "image.mlmodelc"),
                ("TextEncoder.mlmodelc.zip", "TextEncoder.mlmodelc", "text.mlmodelc"),
                ("tokenizer.zip", "tokenizer/tokenizer.json", "tokenizer.json")
            ]
            for job in jobs {
                try Task.checkCancellation()
                let output = extraction.appendingPathComponent(job.archive, isDirectory: true)
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
                try extractZip(
                    archives.appendingPathComponent(job.archive),
                    to: output
                )
                let match = output.appendingPathComponent(job.relativePath)
                let safePrefix = output.standardizedFileURL.path + "/"
                guard match.standardizedFileURL.path.hasPrefix(safePrefix),
                      fm.fileExists(atPath: match.path) else {
                    throw SemanticModelError.invalidArchive(job.archive)
                }
                try fm.moveItem(at: match, to: directory.appendingPathComponent(job.destination))
            }
            try fm.removeItem(at: archives)
            try fm.removeItem(at: extraction)
        }.value
    }

    private nonisolated static func extractZip(_ archive: URL, to destination: URL) throws {
        guard try zipEntriesAreSafe(archive) else {
            throw SemanticModelError.invalidArchive(archive.lastPathComponent)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SemanticModelError.invalidArchive(archive.lastPathComponent)
        }
    }

    private nonisolated static func zipEntriesAreSafe(_ archive: URL) throws -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let listing = String(data: data, encoding: .utf8) else { return false }
        return listing.split(whereSeparator: \ .isNewline).allSatisfy { entry in
            let path = String(entry).replacingOccurrences(of: "\\", with: "/")
            let components = path.split(separator: "/")
            return !components.isEmpty
                && !path.hasPrefix("/")
                && !components.contains("..")
        }
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 1 << 20)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func isInstalled(_ descriptor: SemanticModelDescriptor) -> Bool {
        FileManager.default.fileExists(
            atPath: modelDirectory(for: descriptor).appendingPathComponent("complete").path
        )
    }

    nonisolated static func modelDirectory(for descriptor: SemanticModelDescriptor) -> URL {
        SemanticModelStorage.rootDirectory.appendingPathComponent(descriptor.id, isDirectory: true)
    }
}

enum SemanticModelError: LocalizedError {
    case unavailable
    case notInstalled
    case invalidDownloadURL
    case downloadFailed(String)
    case checksumMismatch(String)
    case invalidTokenizer
    case invalidModelOutput
    case unreadableImage
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This model is not available yet."
        case .notInstalled: return "Download the selected semantic model first."
        case .invalidDownloadURL: return "The model download URL is invalid."
        case .downloadFailed(let path): return "Could not download \(path)."
        case .checksumMismatch(let path): return "Model verification failed for \(path)."
        case .invalidTokenizer: return "The model tokenizer is invalid."
        case .invalidModelOutput: return "The model returned an invalid embedding."
        case .unreadableImage: return "The image could not be loaded for semantic analysis."
        case .invalidArchive(let name): return "The downloaded model archive is invalid: \(name)."
        }
    }
}

final class SemanticModelSession: @unchecked Sendable {
    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: any SemanticTextTokenizer
    private let imageSize: Int
    private let runtime: SemanticModelRuntime

    init(descriptor: SemanticModelDescriptor) throws {
        guard SemanticModelManager.isInstalled(descriptor) else {
            throw SemanticModelError.notInstalled
        }
        let directory = SemanticModelManager.modelDirectory(for: descriptor)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        imageModel = try MLModel(
            contentsOf: directory.appendingPathComponent("image.mlmodelc"),
            configuration: configuration
        )
        textModel = try MLModel(
            contentsOf: directory.appendingPathComponent("text.mlmodelc"),
            configuration: configuration
        )
        switch descriptor.runtime.tokenizer {
        case .clipBPE:
            tokenizer = try CLIPTokenizer(
                vocabularyURL: directory.appendingPathComponent("vocab.json"),
                mergesURL: directory.appendingPathComponent("merges.txt")
            )
        case .sigLIP2BPE:
            tokenizer = try SigLIP2Tokenizer(
                tokenizerURL: directory.appendingPathComponent("tokenizer.json")
            )
        }
        imageSize = descriptor.imageSize
        runtime = descriptor.runtime
    }

    func imageEmbedding(for url: URL) throws -> [Float] {
        let input = try MLFeatureValue(
            imageAt: url,
            pixelsWide: imageSize,
            pixelsHigh: imageSize,
            pixelFormatType: kCVPixelFormatType_32ARGB,
            options: [
                .cropAndScale: (
                    runtime.imageScaling == .centerCrop
                        ? VNImageCropAndScaleOption.centerCrop
                        : VNImageCropAndScaleOption.scaleFill
                ).rawValue
            ]
        )
        guard let pixelBuffer = input.imageBufferValue else { throw SemanticModelError.unreadableImage }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            runtime.imageInput: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let output = try imageModel.prediction(from: provider)
        return try embedding(from: output)
    }

    func textEmbedding(for query: String) throws -> [Float] {
        let tokens = try tokenizer.encode(query)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            runtime.textInput: MLFeatureValue(multiArray: tokens)
        ])
        let output = try textModel.prediction(from: provider)
        return try embedding(from: output)
    }

    static func cosineSimilarity(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var dot: Float = 0
        var firstNorm: Float = 0
        var secondNorm: Float = 0
        for index in first.indices {
            dot += first[index] * second[index]
            firstNorm += first[index] * first[index]
            secondNorm += second[index] * second[index]
        }
        let denominator = sqrt(firstNorm) * sqrt(secondNorm)
        return denominator > 0 ? dot / denominator : 0
    }

    private func embedding(from provider: MLFeatureProvider) throws -> [Float] {
        guard let array = provider.featureValue(for: runtime.embeddingOutput)?.multiArrayValue else {
            throw SemanticModelError.invalidModelOutput
        }
        return (0..<array.count).map { array[$0].floatValue }
    }
}
