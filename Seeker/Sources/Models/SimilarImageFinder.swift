import Foundation
import Vision
import ImageIO
import CoreGraphics

struct SimilarImageCandidate: Sendable {
    let id: String
    let url: URL
}

enum SimilarImageFinder {
    private static let maximumConcurrency = 4
    private static let visionWeight: Float = 0.65
    private static let pHashWeight: Float = 0.25
    private static let aspectWeight: Float = 0.10

    struct Match: Sendable {
        let id: String
        let similarity: Float
        let visionSimilarity: Float
        let pHashSimilarity: Float
        let aspectSimilarity: Float
        let semanticSimilarity: Float?
    }

    private struct ImageFingerprint: @unchecked Sendable {
        let featurePrint: VNFeaturePrintObservation
        let pHash: UInt64
        let aspectRatio: Double
    }

    enum FinderError: LocalizedError {
        case unreadableReference

        var errorDescription: String? {
            switch self {
            case .unreadableReference:
                return "The selected image could not be analyzed."
            }
        }
    }

    static func findSimilar(
        to referenceURL: URL,
        among candidates: [SimilarImageCandidate],
        semanticSession: SemanticModelSession? = nil
    ) async throws -> [Match] {
        guard let reference = fingerprint(for: referenceURL) else {
            throw FinderError.unreadableReference
        }

        let eligible = candidates.filter {
            $0.url.standardizedFileURL != referenceURL.standardizedFileURL
        }
        let workerCount = min(maximumConcurrency, eligible.count)
        guard workerCount > 0 else { return [] }
        let semanticReference = try semanticSession?.imageEmbedding(for: referenceURL)

        let matches = await withTaskGroup(of: [Match].self) { group in
            for workerIndex in 0..<workerCount {
                group.addTask {
                    var workerMatches: [Match] = []
                    for index in stride(from: workerIndex, to: eligible.count, by: workerCount) {
                        if Task.isCancelled { break }
                        if let match = score(
                            candidate: eligible[index],
                            against: reference,
                            semanticSession: semanticSession,
                            semanticReference: semanticReference
                        ) {
                            workerMatches.append(match)
                        }
                    }
                    return workerMatches
                }
            }
            var combined: [Match] = []
            combined.reserveCapacity(eligible.count)
            for await workerMatches in group {
                combined.append(contentsOf: workerMatches)
            }
            return combined
        }
        return matches.sorted { $0.similarity > $1.similarity }
    }

    private static func score(
        candidate: SimilarImageCandidate,
        against reference: ImageFingerprint,
        semanticSession: SemanticModelSession?,
        semanticReference: [Float]?
    ) -> Match? {
        guard let candidateFingerprint = fingerprint(for: candidate.url) else { return nil }
        var visionDistance: Float = 0
        do {
            try reference.featurePrint.computeDistance(
                &visionDistance,
                to: candidateFingerprint.featurePrint
            )
            let visionSimilarity = 1 / (1 + visionDistance / 10)
            let differingBits = (reference.pHash ^ candidateFingerprint.pHash).nonzeroBitCount
            let pHashSimilarity = 1 - Float(differingBits) / 63
            let aspectDelta = abs(log(reference.aspectRatio / candidateFingerprint.aspectRatio))
            let aspectSimilarity = Float(max(0, 1 - aspectDelta / log(2)))
            let visualSimilarity = visionWeight * visionSimilarity
                + pHashWeight * pHashSimilarity
                + aspectWeight * aspectSimilarity
            let semanticSimilarity: Float?
            if let semanticSession, let semanticReference,
               let candidateEmbedding = try? semanticSession.imageEmbedding(for: candidate.url) {
                semanticSimilarity = SemanticModelSession.cosineSimilarity(
                    semanticReference,
                    candidateEmbedding
                )
            } else {
                semanticSimilarity = nil
            }
            let similarity = semanticSimilarity.map {
                0.65 * visualSimilarity + 0.35 * max(0, $0)
            } ?? visualSimilarity
            return Match(
                id: candidate.id,
                similarity: similarity,
                visionSimilarity: visionSimilarity,
                pHashSimilarity: pHashSimilarity,
                aspectSimilarity: aspectSimilarity,
                semanticSimilarity: semanticSimilarity
            )
        } catch {
            return nil
        }
    }

    private static func fingerprint(for url: URL) -> ImageFingerprint? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url)
        do {
            try handler.perform([request])
            guard let featurePrint = request.results?.first,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Double,
                  let height = properties[kCGImagePropertyPixelHeight] as? Double,
                  width > 0, height > 0,
                  let pHash = perceptualHash(source: source) else { return nil }
                        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
                        let swapsDimensions = (5...8).contains(orientation)
            return ImageFingerprint(
                featurePrint: featurePrint,
                pHash: pHash,
                                aspectRatio: swapsDimensions ? height / width : width / height
            )
        } catch {
            return nil
        }
    }

    private static func perceptualHash(source: CGImageSource) -> UInt64? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { return nil }

        var lowFrequencies = [Double]()
        lowFrequencies.reserveCapacity(64)
        let factor = Double.pi / Double(2 * size)
        for verticalFrequency in 0..<8 {
            for horizontalFrequency in 0..<8 {
                var sum = 0.0
                for y in 0..<size {
                    let verticalCosine = cos(Double((2 * y + 1) * verticalFrequency) * factor)
                    for x in 0..<size {
                        let horizontalCosine = cos(Double((2 * x + 1) * horizontalFrequency) * factor)
                        sum += Double(pixels[y * size + x]) * horizontalCosine * verticalCosine
                    }
                }
                lowFrequencies.append(sum)
            }
        }

        let medianSource = lowFrequencies.dropFirst().sorted()
        guard !medianSource.isEmpty else { return nil }
        let median = medianSource[medianSource.count / 2]
        var hash: UInt64 = 0
        for (index, coefficient) in lowFrequencies.enumerated()
            where index > 0 && coefficient > median {
            hash |= UInt64(1) << UInt64(index)
        }
        return hash
    }
}
