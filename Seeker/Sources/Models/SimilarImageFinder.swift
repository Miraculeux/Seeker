import Foundation
import Vision

struct SimilarImageCandidate: Sendable {
    let id: String
    let url: URL
}

enum SimilarImageFinder {
    struct Match: Sendable {
        let id: String
        let distance: Float
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
        among candidates: [SimilarImageCandidate]
    ) throws -> [Match] {
        guard let reference = featurePrint(for: referenceURL) else {
            throw FinderError.unreadableReference
        }

        var matches: [Match] = []
        matches.reserveCapacity(candidates.count)
        for candidate in candidates {
            if Task.isCancelled { break }
            guard candidate.url.standardizedFileURL != referenceURL.standardizedFileURL,
                  let observation = featurePrint(for: candidate.url) else { continue }
            var distance: Float = 0
            do {
                try reference.computeDistance(&distance, to: observation)
                matches.append(Match(id: candidate.id, distance: distance))
            } catch {
                continue
            }
        }
        return matches.sorted { $0.distance < $1.distance }
    }

    private static func featurePrint(for url: URL) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url)
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }
}
