import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Seeker

@MainActor
final class BrowserDropImporterTests: XCTestCase {
    func testUniqueDestinationUsesOriginalNameWhenAvailable() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            BrowserDropImporter.uniqueDestination(in: root, name: "photo.png"),
            root.appendingPathComponent("photo.png")
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testUniqueDestinationSkipsOccupiedSuffixesAndPreservesCompoundExtension() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["archive.tar.gz", "archive.tar 2.gz"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(
            BrowserDropImporter.uniqueDestination(in: root, name: "archive.tar.gz").lastPathComponent,
            "archive.tar 3.gz"
        )
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("archive.tar.gz")), Data("archive.tar.gz".utf8))
    }

    func testUniqueDestinationHandlesExtensionlessNamesAndDirectoryCollisions() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("image"), withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent("image 2"))
        XCTAssertEqual(BrowserDropImporter.uniqueDestination(in: root, name: "image").lastPathComponent, "image 3")
    }

    func testConcreteImageImportPreservesBytesAndCompletesOnMainThread() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let provider = provider(type: .png, data: payload, name: "photo")
        try await importAndWait([provider], into: root)

        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo.png")), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["photo.png"])
    }

    func testImportSanitizesSuggestedNameWithoutEscapingDestination() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("image bytes".utf8)
        let provider = provider(type: .png, data: payload, name: "../../escaped/\0.png")
        try await importAndWait([provider], into: root)

        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), [".._.._escaped__.png"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), payload)
    }

    func testImportPreservesExistingFileOnNameCollision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("original".utf8)
        let imported = Data("new".utf8)
        try original.write(to: root.appendingPathComponent("photo.png"))
        try await importAndWait([provider(type: .png, data: imported, name: "photo.png")], into: root)

        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo.png")), original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo 2.png")), imported)
    }

    func testConcreteImagePriorityChoosesPNGWithoutReencodingJPEG() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data("PNG payload".utf8)
        let item = provider(type: .png, data: png, name: "priority")
        item.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(Data("JPEG payload".utf8), nil)
            return nil
        }
        try await importAndWait([item], into: root)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["priority.png"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("priority.png")), png)
    }

    func testGenericImageImportDetectsSupportedMagicNumbers() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, Data, String)] = [
            ("png", Data([0x89, 0x50, 0x4E, 0x47]), "png"),
            ("jpeg", Data([0xFF, 0xD8, 0xFF, 0xE0]), "jpg"),
            ("tiff-little", Data([0x49, 0x49, 0x2A, 0]), "tiff"),
            ("tiff-big", Data([0x4D, 0x4D, 0, 0x2A]), "tiff"),
            ("gif", Data("GIF89a".utf8), "gif"),
            ("webp", Data("RIFFxxxxWEBP".utf8), "webp"),
            ("bmp", Data([0x42, 0x4D, 0, 0]), "bmp"),
            ("unknown", Data([1, 2, 3, 4]), "png"),
            ("short", Data([1]), "png")
        ]
        for (name, data, ext) in cases {
            try await importAndWait([provider(type: .image, data: data, name: name)], into: root)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(name).\(ext)")), data, name)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, cases.count)
    }

    func testImportAddsExtensionOnlyWhenSuggestedNameHasNone() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["upper.PNG", "other.custom"] {
            let data = Data(name.utf8)
            try await importAndWait([provider(type: .png, data: data, name: name)], into: root)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), data)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["upper.PNG", "other.custom"])
    }

    func testBlankSuggestedNameUsesGeneratedImageName() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data([1, 2, 3])
        try await importAndWait([provider(type: .png, data: data, name: "   ")], into: root)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        XCTAssertTrue(file.lastPathComponent.hasPrefix("Image-"))
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testBatchCompletesOnceWhenSomeProvidersAreUnsupported() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = provider(type: .png, data: Data([1]), name: "first")
        let second = provider(type: .png, data: Data([2]), name: "second")
        let unsupported = provider(type: .plainText, data: Data("text".utf8), name: "ignored")
        try await importAndWait([first, second, unsupported], into: root)

        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["first.png", "second.png"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("first.png")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("second.png")), Data([2]))
    }

    func testFailedProviderDoesNotWriteOrReportSuccessfulImport() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = expectation(description: "Provider attempted")
        let success = expectation(description: "No successful import")
        success.isInverted = true
        let item = NSItemProvider()
        item.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            loaded.fulfill()
            return nil
        }
        BrowserDropImporter.importProviders([item], into: root) { success.fulfill() }
        await fulfillment(of: [loaded], timeout: 5)
        await fulfillment(of: [success], timeout: 0.2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testUnwritableDestinationDoesNotReportSuccessfulImport() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = expectation(description: "Provider supplied image")
        let success = expectation(description: "Failed write must not succeed")
        success.isInverted = true
        let item = NSItemProvider()
        item.suggestedName = "photo"
        item.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(Data([1, 2, 3]), nil)
            loaded.fulfill()
            return nil
        }
        let missingDirectory = root.appendingPathComponent("missing", isDirectory: true)
        BrowserDropImporter.importProviders([item], into: missingDirectory) { success.fulfill() }
        await fulfillment(of: [loaded], timeout: 5)
        await fulfillment(of: [success], timeout: 0.2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testNonHTTPURLDoesNotDownloadOrReportSuccessfulImport() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let success = expectation(description: "Unsupported URL scheme must not succeed")
        success.isInverted = true
        let url = try XCTUnwrap(NSURL(string: "ftp://example.invalid/image.png"))
        let item = NSItemProvider(object: url)
        BrowserDropImporter.importProviders([item], into: root) { success.fulfill() }
        await fulfillment(of: [success], timeout: 0.2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testEmptyBatchDoesNotReportSuccessfulImport() async {
        let success = expectation(description: "Empty batch must not succeed")
        success.isInverted = true
        BrowserDropImporter.importProviders([], into: FileManager.default.temporaryDirectory) { success.fulfill() }
        await fulfillment(of: [success], timeout: 0.2)
    }

    private func importAndWait(_ providers: [NSItemProvider], into root: URL) async throws {
        let saved = expectation(description: "Batch import completed")
        saved.assertForOverFulfill = true
        BrowserDropImporter.importProviders(providers, into: root) {
            XCTAssertTrue(Thread.isMainThread)
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 5)
    }

    private func provider(type: UTType, data: Data, name: String) -> NSItemProvider {
        let item = NSItemProvider()
        item.suggestedName = name
        item.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return item
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Seeker-browser-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
