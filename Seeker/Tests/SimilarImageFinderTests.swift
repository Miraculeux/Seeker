import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Seeker

final class SimilarImageFinderTests: XCTestCase, @unchecked Sendable {
    func testUnreadableReferenceThrowsRatherThanReturningNoMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing.png")
        do {
            _ = try await SimilarImageFinder.findSimilar(to: missing, among: [])
            XCTFail("A reference that cannot be analyzed must report an error")
        } catch SimilarImageFinder.FinderError.unreadableReference {
        }
    }

    func testMalformedReferenceReportsAnalysisFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let malformed = fixture.root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: malformed)
        do {
            _ = try await SimilarImageFinder.findSimilar(to: malformed, among: [])
            XCTFail("Malformed images must not produce successful empty results")
        } catch SimilarImageFinder.FinderError.unreadableReference {
        }
    }

    func testEmptyCandidatesAndReferenceOnlyCandidateProduceNoMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try fixture.image("reference.png")
        let empty = try await SimilarImageFinder.findSimilar(to: reference, among: [])
        XCTAssertTrue(empty.isEmpty)

        let equivalent = fixture.root.appendingPathComponent("unused/../reference.png")
        let referenceOnly = try await SimilarImageFinder.findSimilar(
            to: reference, among: [.init(id: "self", url: equivalent)]
        )
        XCTAssertTrue(referenceOnly.isEmpty)
    }

    func testIdenticalImageScoresOneWithoutSemanticModel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try fixture.image("reference.png")
        let copy = fixture.root.appendingPathComponent("copy.png")
        try FileManager.default.copyItem(at: reference, to: copy)
        let matches = try await SimilarImageFinder.findSimilar(
            to: reference, among: [.init(id: "copy", url: copy)]
        )
        let match = try XCTUnwrap(matches.first)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(match.id, "copy")
        XCTAssertEqual(match.visionSimilarity, 1, accuracy: 0.0001)
        XCTAssertEqual(match.pHashSimilarity, 1, accuracy: 0.0001)
        XCTAssertEqual(match.aspectSimilarity, 1, accuracy: 0.0001)
        XCTAssertEqual(match.similarity, 1, accuracy: 0.0001)
        XCTAssertNil(match.semanticSimilarity)
    }

    func testUnreadableCandidatesAreSkippedWithoutLosingValidMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try fixture.image("reference.png")
        let valid = try fixture.image("valid.png")
        let malformed = fixture.root.appendingPathComponent("malformed.png")
        try Data([0, 1, 2, 3]).write(to: malformed)
        let matches = try await SimilarImageFinder.findSimilar(to: reference, among: [
            .init(id: "missing", url: fixture.root.appendingPathComponent("missing.png")),
            .init(id: "malformed", url: malformed),
            .init(id: "valid", url: valid),
            .init(id: "self", url: reference)
        ])

        XCTAssertEqual(matches.map(\.id), ["valid"])
    }

    func testScoringIsBoundedSortedAndAccountsForAspectRatioAcrossWorkers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try fixture.image("reference.png")
        var candidates: [SimilarImageCandidate] = []
        for index in 0..<7 {
            let url = try fixture.image("candidate-\(index).png", width: index == 6 ? 128 : 64)
            candidates.append(.init(id: "\(index)", url: url))
        }
        let matches = try await SimilarImageFinder.findSimilar(to: reference, among: candidates)

        XCTAssertEqual(Set(matches.map(\.id)), Set(candidates.map(\.id)))
        XCTAssertEqual(matches.map(\.similarity), matches.map(\.similarity).sorted(by: >))
        for match in matches {
            for value in [match.similarity, match.visionSimilarity, match.pHashSimilarity, match.aspectSimilarity] {
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
            XCTAssertEqual(
                match.similarity,
                0.65 * match.visionSimilarity + 0.25 * match.pHashSimilarity + 0.10 * match.aspectSimilarity,
                accuracy: 0.0001
            )
        }
        let wide = try XCTUnwrap(matches.first { $0.id == "6" })
        XCTAssertEqual(wide.aspectSimilarity, 0, accuracy: 0.0001)
    }

    func testPreCancelledSearchDoesNotPublishCandidateScores() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try fixture.image("reference.png")
        let candidate = try fixture.image("candidate.png")
        let task = Task {
            try await SimilarImageFinder.findSimilar(to: reference, among: [.init(id: "candidate", url: candidate)])
        }
        task.cancel()
        let matches = try await task.value
        XCTAssertTrue(matches.isEmpty)
    }

    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Seeker-similar-images-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func image(_ name: String, width: Int = 64, height: Int = 64) throws -> URL {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    pixels[offset] = UInt8((x * 3) % 256)
                    pixels[offset + 1] = UInt8((y * 3) % 256)
                    pixels[offset + 2] = (x / 8 + y / 8).isMultiple(of: 2) ? 240 : 16
                    pixels[offset + 3] = 255
                }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
            let image = try XCTUnwrap(CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ))
            let url = root.appendingPathComponent(name)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
