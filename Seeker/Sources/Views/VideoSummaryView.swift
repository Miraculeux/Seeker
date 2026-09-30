import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct VideoSummaryRequest: Codable, Hashable {
    let url: URL
    let sourceWindowID: UUID
}

@MainActor @Observable
final class VideoSummaryModel {
    private(set) var summary: VideoSummary?
    private(set) var isGenerating = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var message: String?
    private(set) var needsFFmpegInstallation = false
    @ObservationIgnored private var worker: Task<VideoSummary, Error>?
    @ObservationIgnored private var generationID = UUID()

    func generate(
        url: URL, useCache: Bool, cache: VideoSummaryCache = .shared,
        ffmpegSearchDirectories: [URL]? = nil
    ) async {
        worker?.cancel()
        let id = UUID()
        generationID = id
        summary = nil
        message = nil
        needsFFmpegInstallation = false
        completed = 0
        total = 0
        isGenerating = true
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try await VideoSummaryService.generate(
                url: url, cache: cache, useCache: useCache, ffmpegSearchDirectories: ffmpegSearchDirectories
            ) { [weak self] completed, total in
                await self?.updateProgress(completed, total, generationID: id)
            }
        }
        worker = task
        defer {
            if generationID == id {
                worker = nil
                isGenerating = false
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            if generationID == id { summary = result }
        } catch is CancellationError {
            if generationID == id { message = "Generation cancelled." }
        } catch FFmpegVideoBackend.BackendError.missingTools(let nativeFailure) {
            if generationID == id {
                needsFFmpegInstallation = true
                message = FFmpegVideoBackend.BackendError.missingTools(nativeFailure: nativeFailure).localizedDescription
            }
        } catch {
            if generationID == id { message = error.localizedDescription }
        }
    }

    private func updateProgress(_ completed: Int, _ total: Int, generationID: UUID) {
        guard self.generationID == generationID else { return }
        self.completed = completed
        self.total = total
    }

    func cancel() {
        worker?.cancel()
    }
}

struct VideoSummaryView: View {
    let url: URL
    @State private var model = VideoSummaryModel()
    @State private var generation = 0
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "film.stack")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Video Summary").font(.headline)
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }
                Spacer()
                if model.isGenerating {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Generate Again") { generation += 1 }
                }
                Button {
                    export()
                } label: {
                    Label("Export PNG", systemImage: "square.and.arrow.up")
                }
                .disabled(model.summary == nil || model.isGenerating)
            }
            .padding(14)
            Divider()
            content
        }
        .frame(minWidth: 720, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 480, idealHeight: 720, maxHeight: .infinity)
        .toolWindowURLs([url])
        .task(id: generation) { await model.generate(url: url, useCache: generation == 0) }
        .onDisappear { model.cancel() }
        .alert("Could Not Export Summary", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isGenerating {
            VStack(spacing: 12) {
                if model.total > 0 {
                    ProgressView(value: Double(model.completed), total: Double(model.total))
                        .frame(width: 320)
                    Text("Analyzing sample \(model.completed) of \(model.total)")
                } else {
                    ProgressView()
                    Text("Opening video")
                }
                Text("Sampling, filtering and removing duplicate frames locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let summary = model.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(summary.frames.count) representative frames \u{00B7} \(VideoSummaryService.timestamp(summary.duration))")
                        .font(.subheadline)
                    Text("Sparse visual summary, not AI scene understanding. Short scenes may be missed; repetitive videos may produce fewer frames.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(summary.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 16) {
                        ForEach(summary.frames) { frame in
                            VStack(spacing: 6) {
                                Image(decorative: frame.image, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 150)
                                    .frame(maxWidth: .infinity)
                                    .background(.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(VideoSummaryService.timestamp(frame.seconds))
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Video frame at \(VideoSummaryService.timestamp(frame.seconds))")
                        }
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView {
                Label(model.needsFFmpegInstallation ? "Install FFmpeg" : "Summary Not Generated", systemImage: "film.stack")
            } description: {
                Text(model.message ?? "Generate a summary to view representative frames.")
                    .textSelection(.enabled)
            } actions: {
                if model.needsFFmpegInstallation {
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                    }
                    Link("Installation Guide", destination: URL(string: "https://formulae.brew.sh/formula/ffmpeg")!)
                }
            }
        }
    }

    private func export() {
        guard let summary = model.summary else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-summary.png"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                let data = try VideoSummaryExporter.png(summary: summary, name: url.lastPathComponent)
                try data.write(to: destination, options: .atomic)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

@MainActor
enum VideoSummaryExporter {
    static func png(summary: VideoSummary, name: String) throws -> Data {
        guard !summary.frames.isEmpty, summary.frames.count <= VideoSummaryService.maximumFrames else {
            throw VideoSummaryService.SummaryError.noUsableFrames
        }
        let columns = min(4, summary.frames.count)
        let rows = (summary.frames.count + columns - 1) / columns
        let padding = 16
        let cellWidth = 480
        let cellHeight = 304
        let header = 72
        let width = padding + columns * (cellWidth + padding)
        let height = header + rows * (cellHeight + padding)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw VideoSummaryService.SummaryError.imageProcessing
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (name as NSString).draw(
            in: NSRect(x: padding, y: height - 34, width: width - padding * 2, height: 24),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white,
                             .paragraphStyle: paragraph]
        )
        ("\(VideoSummaryService.timestamp(summary.duration)) | \(summary.frames.count) representative frames" as NSString)
            .draw(at: NSPoint(x: padding, y: height - 56), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.lightGray
            ])
        for (index, frame) in summary.frames.enumerated() {
            let x = CGFloat(padding + (index % columns) * (cellWidth + padding))
            let top = CGFloat(height - header - (index / columns) * (cellHeight + padding))
            let imageRect = NSRect(x: x, y: top - 270, width: CGFloat(cellWidth), height: 270)
            NSColor.black.setFill()
            imageRect.fill()
            let scale = min(imageRect.width / CGFloat(frame.image.width),
                            imageRect.height / CGFloat(frame.image.height))
            let size = NSSize(width: CGFloat(frame.image.width) * scale,
                              height: CGFloat(frame.image.height) * scale)
            context.cgContext.draw(frame.image, in: NSRect(
                x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2,
                width: size.width, height: size.height
            ))
            (VideoSummaryService.timestamp(frame.seconds) as NSString).draw(
                at: NSPoint(x: x, y: top - 294),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
                                 .foregroundColor: NSColor.white]
            )
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw VideoSummaryService.SummaryError.imageProcessing
        }
        return data
    }
}
