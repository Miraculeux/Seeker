import Foundation
import XCTest
@testable import Seeker

final class MediaMetadataServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try MetadataTestFixtures.makeDirectory()
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func fixture(_ ext: String, bytes: Data? = nil) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try (bytes ?? MetadataTestFixtures.container(for: ext)).write(to: url)
        return url
    }

    private var metadata: MediaMetadata {
        MediaMetadata(tags: [.init(key: "title", value: "Synthetic title"),
                             .init(key: "artist", value: "Test artist"),
                             .init(key: "album", value: "Test album")])
    }

    private func assertRoundTrip(_ extensions: [String], cover: Bool = false) async throws {
        var input = metadata
        if cover { input.coverArt = try MetadataTestFixtures.imageData(type: .png) }
        for ext in extensions {
            let url = try fixture(ext)
            let before = try await MediaMetadataService.read(url)
            XCTAssertTrue(before.tags.isEmpty, ext)
            try MediaMetadataService.write(input, to: url)
            let output = try await MediaMetadataService.read(url)
            XCTAssertEqual(output.title, input.title, ext)
            XCTAssertEqual(output.artist, input.artist, ext)
            XCTAssertEqual(output.album, input.album, ext)
            XCTAssertTrue(output.tags.allSatisfy { $0.key == $0.key.uppercased() }, ext)
            if cover {
                XCTAssertEqual(output.coverArt, input.coverArt, ext)
                XCTAssertEqual(output.coverMimeType, "image/png", ext)
            }
            XCTAssertNotNil(try Data(contentsOf: url).range(of: MetadataTestFixtures.payload), ext)
        }
    }

    func testExtensionRoutingIsCaseInsensitiveAndSetsAreDisjoint() {
        let writable: Set<String> = [
            "flac", "mp3", "m4a", "m4b", "mp4", "m4v", "mov", "alac",
            "aiff", "aif", "aifc", "mka", "mkv", "webm", "avi", "dsf", "dff"
        ]
        let readOnly: Set<String> = ["wav", "aac", "ogg", "opus", "wma", "ts", "mpg",
                                     "mpeg", "wmv", "flv"]
        XCTAssertEqual(MediaMetadataService.writableExtensions, writable)
        XCTAssertEqual(MediaMetadataService.readOnlyExtensions, readOnly)
        for ext in writable.union(readOnly) {
            let url = root.appendingPathComponent("fixture.\(ext.uppercased())")
            XCTAssertTrue(MediaMetadataService.isReadable(url), ext)
            XCTAssertEqual(MediaMetadataService.isSupported(url), writable.contains(ext), ext)
            XCTAssertEqual(MediaMetadataService.isReadOnly(url), readOnly.contains(ext), ext)
        }
        for name in ["image.jpg", "audio.mp3.backup", "no-extension", ".mp3"] {
            let url = root.appendingPathComponent(name)
            XCTAssertFalse(MediaMetadataService.isReadable(url), name)
            XCTAssertFalse(MediaMetadataService.isSupported(url), name)
            XCTAssertFalse(MediaMetadataService.isReadOnly(url), name)
        }
    }

    func testUnsupportedReadAndWriteUseDistinctErrorsWithoutChangingFile() async throws {
        let bytes = Data("not media".utf8)
        let url = try fixture("xyz", bytes: bytes)
        do {
            _ = try await MediaMetadataService.read(url)
            XCTFail("Unsupported read must throw")
        } catch {
            XCTAssertEqual((error as NSError).domain, "MediaMetadataService")
            XCTAssertEqual((error as NSError).code, 1)
        }
        XCTAssertThrowsError(try MediaMetadataService.write(metadata, to: url)) { error in
            XCTAssertEqual((error as NSError).domain, "MediaMetadataService")
            XCTAssertEqual((error as NSError).code, 2)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testReadOnlyFormatsRefuseWritesAndMalformedWAVReadsBestEffort() async throws {
        let bytes = Data("invalid read-only media".utf8)
        for ext in MediaMetadataService.readOnlyExtensions {
            let url = try fixture(ext.uppercased(), bytes: bytes)
            XCTAssertThrowsError(try MediaMetadataService.write(metadata, to: url)) { error in
                XCTAssertEqual((error as NSError).domain, "MediaMetadataService")
                XCTAssertEqual((error as NSError).code, 3)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        let wav = try fixture("wav", bytes: bytes)
        let output = try await MediaMetadataService.read(wav)
        XCTAssertTrue(output.tags.isEmpty)
        XCTAssertNil(output.vendor)
        XCTAssertNil(output.coverArt)
    }

    func testMP3RoutingInfersCoverMIMEAndPreservesAudio() async throws {
        try await assertRoundTrip(["MP3"], cover: true)
        let url = try fixture("mp3")
        var input = metadata
        input.coverArt = Data([1, 2, 3])
        try MediaMetadataService.write(input, to: url)
        let output = try await MediaMetadataService.read(url)
        XCTAssertEqual(output.coverArt, input.coverArt)
        XCTAssertEqual(output.coverMimeType, "image/jpeg")
    }

    func testFLACRoutingWritesVendorCustomTagsAndCoverDimensions() async throws {
        let url = try fixture("flac")
        var input = metadata
        input.vendor = "Synthetic vendor"
        input.tags.append(.init(key: "mood", value: "Calm"))
        input.coverArt = try MetadataTestFixtures.imageData(type: .png)
        try MediaMetadataService.write(input, to: url)
        let output = try await MediaMetadataService.read(url)
        XCTAssertEqual(output.vendor, "Synthetic vendor")
        XCTAssertEqual(output.title, "Synthetic title")
        XCTAssertEqual(output.first("MOOD"), "Calm")
        XCTAssertEqual(output.coverArt, input.coverArt)
        XCTAssertEqual(output.coverMimeType, "image/png")
        let file = try FlacFile.read(url)
        let picture = try XCTUnwrap(file.firstPicture)
        XCTAssertEqual(picture.width, 4)
        XCTAssertEqual(picture.height, 3)
        XCTAssertEqual(Data(try Data(contentsOf: url).dropFirst(file.audioOffset)),
                       MetadataTestFixtures.payload)
        input.vendor = nil
        try MediaMetadataService.write(input, to: url)
        let rewritten = try await MediaMetadataService.read(url)
        XCTAssertEqual(rewritten.vendor, "Seeker")
    }

    func testMP4ContainerAliasesRouteTagsAndCover() async throws {
        try await assertRoundTrip(["m4a", "m4b", "mp4", "m4v", "mov", "alac"], cover: true)
    }

    func testAIFFContainerAliasesRouteEmbeddedID3AndCover() async throws {
        try await assertRoundTrip(["aiff", "aif", "aifc"], cover: true)
    }

    func testMatroskaContainerAliasesRouteTagsAndAttachments() async throws {
        try await assertRoundTrip(["mka", "mkv", "webm"], cover: true)
    }

    func testAVIAndDSDContainersRouteTagsWithoutChangingMedia() async throws {
        try await assertRoundTrip(["avi"])
        try await assertRoundTrip(["dsf", "dff"], cover: true)
    }

    func testMalformedNativeInputsRejectWritesAndStrictReadersRejectHeaders() async throws {
        let badID3 = ID3v2File.encodeTag(
            frames: [ID3Frame(id: "TIT2", data: ID3Frame.encodeText("old"))], padding: 0).prefix(10)
        for ext in ["flac", "mp3", "mp4", "aiff", "mkv", "avi", "dsf", "dff"] {
            let bytes = ext == "mp3" ? Data(badID3) : Data([0, 1, 2])
            let url = try fixture(ext, bytes: bytes)
            XCTAssertThrowsError(try MediaMetadataService.write(metadata, to: url), ext)
            XCTAssertEqual(try Data(contentsOf: url), bytes, ext)
            if ext != "mp4" {
                do {
                    _ = try await MediaMetadataService.read(url)
                    XCTFail("Malformed \(ext) header must throw")
                } catch {
                    XCTAssertFalse((error as NSError).localizedDescription.isEmpty)
                }
            }
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.contains(".tmp-") })
    }
}
