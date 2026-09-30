import CoreML
import Foundation
import XCTest
@testable import Seeker

final class SemanticTokenizerTestAssets {
    let root: URL

    init() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = repository.appendingPathComponent(".semantic-tokenizer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func write(_ name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func clip(vocabulary: [String: Int], merges: String = "#version: 0.2\n") throws -> CLIPTokenizer {
        let vocabularyURL = try write("vocab.json", data: JSONEncoder().encode(vocabulary))
        let mergesURL = try write("merges.txt", data: Data(merges.utf8))
        return try CLIPTokenizer(vocabularyURL: vocabularyURL, mergesURL: mergesURL)
    }

    func sigLIP(vocabulary: [String: Int], merges: [[String]] = []) throws -> SigLIP2Tokenizer {
        let data = try JSONSerialization.data(withJSONObject: [
            "model": ["vocab": vocabulary, "merges": merges]
        ])
        return try SigLIP2Tokenizer(tokenizerURL: write("tokenizer.json", data: data))
    }

    func cleanup(file: StaticString = #filePath, line: UInt = #line) {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            XCTFail("Tokenizer fixture cleanup failed: \(error)", file: file, line: line)
        }
    }

    static func assertTokens(
        _ output: MLMultiArray,
        prefix: [Int],
        length: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(output.shape, [NSNumber(value: 1), NSNumber(value: length)], file: file, line: line)
        XCTAssertEqual(output.dataType, .int32, file: file, line: line)
        let actual = (0..<output.count).map { output[$0].intValue }
        XCTAssertEqual(actual, prefix + Array(repeating: 0, count: max(0, length - prefix.count)),
                       file: file, line: line)
    }
}
