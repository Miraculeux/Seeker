import Foundation
import XCTest
@testable import Seeker

final class SigLIP2TokenizerTests: XCTestCase {
    func testEmptyInputHasEndTokenAndZeroPadding() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.sigLIP(vocabulary: [:])
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode(""), prefix: [1], length: 64)
    }

    func testSpacesBecomeExplicitWordBoundaryPiecesWithoutCollapsing() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.sigLIP(vocabulary: ["▁": 2, "a": 3])
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode(" a  a "),
                                                prefix: [2, 3, 2, 2, 3, 2, 1], length: 64)
    }

    func testCaseIsPreservedAndTabsUseByteFallbackNotSpaceNormalization() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.sigLIP(vocabulary: ["a": 2, "A": 3, "<0x09>": 4, "<0x0A>": 5])
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("aA\t\n"),
                                                prefix: [2, 3, 4, 5, 1], length: 64)
    }

    func testUnknownEmojiFallsBackToUTF8BytesInOrder() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.sigLIP(vocabulary: ["<0xF0>": 2, "<0x9F>": 3, "<0x98>": 4, "<0x80>": 5])
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("😀"), prefix: [2, 3, 4, 5, 1], length: 64)
    }

    func testKnownUnicodeGraphemeIsPreferredOverByteFallback() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.sigLIP(vocabulary: [
            "👩‍💻": 2, "猫": 3, "<0xF0>": 4, "<0xE7>": 5
        ])
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("👩‍💻猫"), prefix: [2, 3, 1], length: 64)
    }

    func testMissingFallbackBytesAreSkippedWhileKnownTokensRemain() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.sigLIP(vocabulary: ["a": 2, "<0xC3>": 3])
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("aéza"), prefix: [2, 3, 2, 1], length: 64)
    }

    func testMergeRanksAndRepeatedPairsWorkWhileInvalidMergeEntriesAreIgnored() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.sigLIP(
            vocabulary: ["a": 2, "b": 3, "c": 4, "abc": 5],
            merges: [[], ["invalid"], ["b", "c"], ["a", "b"], ["a", "bc"], ["too", "many", "items"]]
        )
        SemanticTokenizerTestAssets.assertTokens(try tokenizer.encode("abcabc"), prefix: [5, 5, 1], length: 64)
    }

    func testTruncationReservesEndTokenAtAndBeyondContextBoundary() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        let tokenizer = try assets.sigLIP(vocabulary: ["a": 2])
        for count in [62, 63, 64, 100] {
            SemanticTokenizerTestAssets.assertTokens(
                try tokenizer.encode(String(repeating: "a", count: count)),
                prefix: Array(repeating: 2, count: min(count, 63)) + [1], length: 64
            )
        }
    }

    func testCorruptMissingAndWrongTypeTokenizerFieldsThrow() throws {
        let assets = try SemanticTokenizerTestAssets()
        defer { assets.cleanup() }
        for contents in [
            "not JSON", "{}", #"{"model":{"vocab":{}}}"#,
            #"{"model":{"vocab":{"a":"bad"},"merges":[]}}"#,
            #"{"model":{"vocab":{},"merges":["a b"]}}"#
        ] {
            let url = try assets.write("invalid-tokenizer.json", data: Data(contents.utf8))
            XCTAssertThrowsError(try SigLIP2Tokenizer(tokenizerURL: url))
        }
        XCTAssertThrowsError(try SigLIP2Tokenizer(tokenizerURL: assets.root.appendingPathComponent("missing.json")))
    }
}
