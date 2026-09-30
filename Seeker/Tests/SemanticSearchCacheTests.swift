import Foundation
import SQLite3
import XCTest
@testable import Seeker

@MainActor
final class SemanticSearchCacheTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let cache: SemanticSearchCache

        func file(_ name: String, contents: String = "payload") throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path
            )
            return url
        }

        func execute(_ sql: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(cache.databaseURL.path, &database) == SQLITE_OK, let database else {
                if let database { sqlite3_close(database) }
                throw NSError(domain: "SemanticCacheTests", code: 1)
            }
            defer { sqlite3_close(database) }
            let result = sqlite3_exec(database, sql, nil, nil, nil)
            XCTAssertEqual(result, SQLITE_OK, String(cString: sqlite3_errmsg(database)))
        }
    }

    private func fixture() throws -> Fixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent(".semantic-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let cache = SemanticSearchCache(databaseURL: root.appendingPathComponent("cache.sqlite3"))
        addTeardownBlock {
            await cache.close()
            try FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, cache: cache)
    }

    func testEmbeddingAndOCRPersistAcrossClosedConnections() async throws {
        let fixture = try fixture()
        let url = try fixture.file("persisted")
        await fixture.cache.store(embedding: [0.25, -0.5, 1], for: url, modelID: "model")
        await fixture.cache.store(recognizedText: "文字 'quoted'", for: url)
        await fixture.cache.close()

        let reopened = SemanticSearchCache(databaseURL: fixture.cache.databaseURL)
        let embedding = await reopened.embedding(for: url, modelID: "model")
        let text = await reopened.recognizedText(for: url)
        await reopened.close()
        XCTAssertEqual(embedding, [0.25, -0.5, 1])
        XCTAssertEqual(text, "文字 'quoted'")
    }

    func testKeysIsolateFilesModelNamespacesAndOCRFromEmbeddings() async throws {
        let fixture = try fixture()
        let first = try fixture.file("first")
        let second = try fixture.file("second")
        let model = SemanticModelDescriptor.mobileCLIPS0.cacheNamespace
        let otherModel = SemanticModelDescriptor.mobileCLIPS2.cacheNamespace
        await fixture.cache.store(embedding: [1], for: first, modelID: model)
        await fixture.cache.store(embedding: [2], for: first, modelID: otherModel)
        await fixture.cache.store(embedding: [3], for: second, modelID: model)
        await fixture.cache.store(recognizedText: "first OCR", for: first)
        await fixture.cache.store(recognizedText: "second OCR", for: second)
        await fixture.cache.store(embedding: [4, 5], for: first, modelID: model)

        let firstEmbedding = await fixture.cache.embedding(for: first, modelID: model)
        let otherEmbedding = await fixture.cache.embedding(for: first, modelID: otherModel)
        let secondEmbedding = await fixture.cache.embedding(for: second, modelID: model)
        let missingModel = await fixture.cache.embedding(for: first, modelID: "unknown")
        let firstText = await fixture.cache.recognizedText(for: first)
        let secondText = await fixture.cache.recognizedText(for: second)
        XCTAssertEqual(firstEmbedding, [4, 5])
        XCTAssertEqual(otherEmbedding, [2])
        XCTAssertEqual(secondEmbedding, [3])
        XCTAssertNil(missingModel)
        XCTAssertEqual(firstText, "first OCR")
        XCTAssertEqual(secondText, "second OCR")
    }

    func testSizeChangeInvalidatesEmbeddingAndOCRWithUnchangedModificationDate() async throws {
        let fixture = try fixture()
        let url = try fixture.file("size", contents: "short")
        await fixture.cache.store(embedding: [1], for: url, modelID: "model")
        await fixture.cache.store(recognizedText: "cached", for: url)
        _ = try fixture.file("size", contents: "a much longer payload")
        let freshURL = URL(fileURLWithPath: url.path)
        let embedding = await fixture.cache.embedding(for: freshURL, modelID: "model")
        let text = await fixture.cache.recognizedText(for: freshURL)
        XCTAssertNil(embedding)
        XCTAssertNil(text)
    }

    func testModificationDateChangeInvalidatesSameSizeFile() async throws {
        let fixture = try fixture()
        let url = try fixture.file("modified")
        await fixture.cache.store(embedding: [1], for: url, modelID: "model")
        await fixture.cache.store(recognizedText: "cached", for: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: url.path
        )
        let freshURL = URL(fileURLWithPath: url.path)
        let embedding = await fixture.cache.embedding(for: freshURL, modelID: "model")
        let text = await fixture.cache.recognizedText(for: freshURL)
        XCTAssertNil(embedding)
        XCTAssertNil(text)
        await fixture.cache.store(embedding: [2], for: freshURL, modelID: "model")
        let replacement = await fixture.cache.embedding(for: freshURL, modelID: "model")
        XCTAssertEqual(replacement, [2])
    }

    func testMissingFilesCannotBeReadOrStored() async throws {
        let fixture = try fixture()
        let url = fixture.root.appendingPathComponent("missing")
        await fixture.cache.store(embedding: [1], for: url, modelID: "model")
        await fixture.cache.store(recognizedText: "missing", for: url)
        _ = try fixture.file("missing")
        let embedding = await fixture.cache.embedding(for: url, modelID: "model")
        let text = await fixture.cache.recognizedText(for: url)
        XCTAssertNil(embedding)
        XCTAssertNil(text)
    }

    func testEmptyEmbeddingDoesNotReplaceExistingVector() async throws {
        let fixture = try fixture()
        let url = try fixture.file("empty-vector")
        await fixture.cache.store(embedding: [1, -2], for: url, modelID: "model")
        await fixture.cache.store(embedding: [], for: url, modelID: "model")
        await fixture.cache.store(embedding: [], for: url, modelID: "new-model")
        let existing = await fixture.cache.embedding(for: url, modelID: "model")
        let missing = await fixture.cache.embedding(for: url, modelID: "new-model")
        XCTAssertEqual(existing, [1, -2])
        XCTAssertNil(missing)
    }

    func testOCRSupportsEmptyTextUnicodeAndReplacement() async throws {
        let fixture = try fixture()
        let url = try fixture.file("ocr")
        await fixture.cache.store(recognizedText: "", for: url)
        let empty = await fixture.cache.recognizedText(for: url)
        XCTAssertEqual(empty, "")
        await fixture.cache.store(recognizedText: "猫 😀\n'quoted'", for: url)
        let replacement = await fixture.cache.recognizedText(for: url)
        XCTAssertEqual(replacement, "猫 😀\n'quoted'")
    }

    func testStandardizedPathsShareOneCacheKey() async throws {
        let fixture = try fixture()
        let url = try fixture.file("standardized")
        let alternate = fixture.root.appendingPathComponent(".").appendingPathComponent(url.lastPathComponent)
        await fixture.cache.store(embedding: [1], for: alternate, modelID: "model")
        await fixture.cache.store(recognizedText: "same file", for: alternate)
        let embedding = await fixture.cache.embedding(for: url, modelID: "model")
        let text = await fixture.cache.recognizedText(for: url)
        XCTAssertEqual(embedding, [1])
        XCTAssertEqual(text, "same file")
    }

    func testRemoveAllClearsBothTablesAndAllowsNewWrites() async throws {
        let fixture = try fixture()
        let url = try fixture.file("clear")
        await fixture.cache.store(embedding: [1], for: url, modelID: "model")
        await fixture.cache.store(recognizedText: "cached", for: url)
        await fixture.cache.removeAll()
        let embedding = await fixture.cache.embedding(for: url, modelID: "model")
        let text = await fixture.cache.recognizedText(for: url)
        let size = await fixture.cache.currentSizeBytes()
        XCTAssertNil(embedding)
        XCTAssertNil(text)
        XCTAssertGreaterThan(size, 0)
        await fixture.cache.store(embedding: [2], for: url, modelID: "model")
        let replacement = await fixture.cache.embedding(for: url, modelID: "model")
        XCTAssertEqual(replacement, [2])
    }

    func testPruningSkipsNonpositiveBudgetsAndRemovesOnlyMissingFiles() async throws {
        let fixture = try fixture()
        let missing = try fixture.file("missing-after-store")
        let present = try fixture.file("present")
        for url in [missing, present] {
            await fixture.cache.store(embedding: [1], for: url, modelID: "model")
            await fixture.cache.store(recognizedText: "cached", for: url)
        }
        try FileManager.default.removeItem(at: missing)
        await fixture.cache.pruneMissingEntries(maxChecks: 0)
        await fixture.cache.pruneMissingEntries(maxChecks: -1)
        _ = try fixture.file("missing-after-store")
        let retained = await fixture.cache.embedding(for: missing, modelID: "model")
        XCTAssertEqual(retained, [1])
        try FileManager.default.removeItem(at: missing)
        await fixture.cache.pruneMissingEntries(maxChecks: 100)
        _ = try fixture.file("missing-after-store")
        let removedEmbedding = await fixture.cache.embedding(for: missing, modelID: "model")
        let removedText = await fixture.cache.recognizedText(for: missing)
        let presentEmbedding = await fixture.cache.embedding(for: present, modelID: "model")
        let presentText = await fixture.cache.recognizedText(for: present)
        XCTAssertNil(removedEmbedding)
        XCTAssertNil(removedText)
        XCTAssertEqual(presentEmbedding, [1])
        XCTAssertEqual(presentText, "cached")
    }

    func testMalformedDimensionsAndBlobsReturnMissesAndCanBeReplaced() async throws {
        let fixture = try fixture()
        let url = try fixture.file("malformed")
        for update in [
            "dimension = 0",
            "dimension = -1",
            "dimension = 2, vector = X'00000000'",
            "dimension = 1, vector = X''",
            "dimension = 1, vector = X'00'"
        ] {
            await fixture.cache.store(embedding: [1], for: url, modelID: "model")
            try fixture.execute("UPDATE embeddings SET \(update)")
            let malformed = await fixture.cache.embedding(for: url, modelID: "model")
            XCTAssertNil(malformed, update)
        }
        await fixture.cache.store(embedding: [2], for: url, modelID: "model")
        let repaired = await fixture.cache.embedding(for: url, modelID: "model")
        XCTAssertEqual(repaired, [2])
    }

    func testUnavailableOrCorruptDatabaseAndClosedCacheFailSafely() async throws {
        let fixture = try fixture()
        let url = try fixture.file("source")
        let corruptURL = try fixture.file("corrupt.sqlite3", contents: "not a SQLite database")
        let unavailableURL = fixture.root.appendingPathComponent("missing-parent/cache.sqlite3")
        for databaseURL in [corruptURL, unavailableURL] {
            let cache = SemanticSearchCache(databaseURL: databaseURL)
            await cache.store(embedding: [1], for: url, modelID: "model")
            await cache.store(recognizedText: "cached", for: url)
            await cache.removeAll()
            await cache.pruneMissingEntries(maxChecks: 10)
            let embedding = await cache.embedding(for: url, modelID: "model")
            let text = await cache.recognizedText(for: url)
            await cache.close()
            XCTAssertNil(embedding)
            XCTAssertNil(text)
        }
        await fixture.cache.close()
        await fixture.cache.close()
        await fixture.cache.store(embedding: [1], for: url, modelID: "model")
        let closed = await fixture.cache.embedding(for: url, modelID: "model")
        XCTAssertNil(closed)
    }
}
