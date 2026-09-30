import Foundation
import XCTest
@testable import Seeker

final class CLIPTokenizerTests: XCTestCase {
    private let specialTokens = ["<|startoftext|>": 100, "<|endoftext|>": 101]

    func testEmptyAndWhitespaceOnlyInputHasBoundaryTokensAndPadding() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.clip(vocabulary: specialTokens)
        for text in ["", " \t\n\r "] {
            SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode(text), prefix: [100, 101], length: 77)
        }
    }

    func testLowercasingAndWhitespacePreserveWordBoundaries() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.clip(vocabulary: specialTokens.merging(["a</w>": 2, "b</w>": 3]) { _, new in new })
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode(" A\tB\n a "),
                                                prefix: [100, 2, 3, 2, 101], length: 77)
    }

    func testDigitsAreIndividualTokensRatherThanOneNumber() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.clip(vocabulary: specialTokens.merging(["1</w>": 2, "2</w>": 3]) { _, new in new })
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("121"), prefix: [100, 2, 3, 2, 101], length: 77)
    }

    func testContractionAndPunctuationHaveSeparateEndOfWordMarkers() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.clip(vocabulary: specialTokens.merging([
            "i</w>": 2, "'": 3, "m</w>": 4, "!": 5, "!</w>": 6
        ]) { _, new in new })
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("I'm!!"),
                                                prefix: [100, 2, 3, 4, 5, 6, 101], length: 77)
    }

    func testNonASCIITextUsesUTF8ByteVocabularyAfterLowercasing() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.clip(vocabulary: specialTokens.merging(["Ã": 2, "©</w>": 3]) { _, new in new })
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("É"), prefix: [100, 2, 3, 101], length: 77)
    }

    func testUnknownPiecesAreSkippedWithoutLosingKnownNeighbors() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.clip(vocabulary: specialTokens.merging(["a</w>": 2]) { _, new in new })
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("a z a"),
                                                prefix: [100, 2, 2, 101], length: 77)
    }

    func testMergeRankWinsOverLeftmostPairAndMalformedLinesAreIgnored() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.clip(
            vocabulary: specialTokens.merging(["abc</w>": 2]) { _, new in new },
            merges: "#version: 0.2\nmalformed\nb c</w>\na b\na bc</w>\ntoo many fields\n"
        )
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("abc"),
                                                prefix: [100, 2, 101], length: 77)
    }

    func testTruncationAlwaysReservesSpaceForEndTokenAtContextBoundary() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.clip(vocabulary: specialTokens.merging(["a</w>": 2]) { _, new in new })
        for count in [74, 75, 76, 100] {
            let text = Array(repeating: "a", count: count).joined(separator: " ")
            SemanticTokenizerTestAssets.assertTokens(
                try tokenizer.encode(text), prefix: [100] + Array(repeating: 2, count: min(count, 75)) + [101],
                length: 77
            )
        }
    }

    func testMissingEitherSpecialTokenThrowsInvalidTokenizerAtEncoding() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        for vocabulary in [["<|startoftext|>": 100], ["<|endoftext|>": 101], [:]] {
            let tokenizer = try assets.clip(vocabulary: vocabulary)
            XCTAssertThrowsError(try tokenizer.encode("a")) { error in
                guard case SemanticModelError.invalidTokenizer = error else {
                    return XCTFail("Expected invalidTokenizer, got \(error)")
                }
            }
        }
    }

    func testCorruptOrWrongTypeVocabularyAndMissingMergesThrow() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let merges = try assets.write("merges.txt", data: Data("#version: 0.2\n".utf8))
        for contents in ["not JSON", #"{"a":"not an integer"}"#, "[]"] {
            let vocabulary = try assets.write("invalid-vocab.json", data: Data(contents.utf8))
            XCTAssertThrowsError(try CLIPTokenizer(vocabularyURL: vocabulary, mergesURL: merges))
        }
        let vocabulary = try assets.write("valid-vocab.json", data: JSONEncoder().encode(specialTokens))
        XCTAssertThrowsError(try CLIPTokenizer(
            vocabularyURL: vocabulary, mergesURL: assets.root.appendingPathComponent("missing-merges.txt")
        ))
    }
}
