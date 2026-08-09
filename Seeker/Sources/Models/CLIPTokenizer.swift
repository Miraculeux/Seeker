import Foundation
import CoreML

protocol SemanticTextTokenizer: Sendable {
    func encode(_ text: String) throws -> MLMultiArray
}

private struct CLIPBytePair: Hashable {
    let first: String
    let second: String
}

final class CLIPTokenizer: SemanticTextTokenizer, @unchecked Sendable {
    static let contextLength = 77

    private let ranks: [CLIPBytePair: Int]
    private let vocabulary: [String: Int]
    private let byteEncoder: [UInt8: String]
    private let tokenRegex: NSRegularExpression

    init(vocabularyURL: URL, mergesURL: URL) throws {
        let vocabularyData = try Data(contentsOf: vocabularyURL)
        vocabulary = try JSONDecoder().decode([String: Int].self, from: vocabularyData)

        let merges = try String(contentsOf: mergesURL, encoding: .utf8)
            .split(whereSeparator: \ .isNewline)
            .dropFirst()
        var parsedRanks: [CLIPBytePair: Int] = [:]
        parsedRanks.reserveCapacity(merges.count)
        for (index, line) in merges.enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            parsedRanks[CLIPBytePair(first: String(parts[0]), second: String(parts[1]))] = index
        }
        ranks = parsedRanks
        byteEncoder = Self.makeByteEncoder()
        tokenRegex = try NSRegularExpression(
            pattern: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        )
    }

    func encode(_ text: String) throws -> MLMultiArray {
        guard let startToken = vocabulary["<|startoftext|>"],
              let endToken = vocabulary["<|endoftext|>"] else {
            throw SemanticModelError.invalidTokenizer
        }

        var tokenIDs: [Int] = []
        let lowercased = text.lowercased()
        let range = NSRange(lowercased.startIndex..<lowercased.endIndex, in: lowercased)
        for match in tokenRegex.matches(in: lowercased, range: range) {
            guard let tokenRange = Range(match.range, in: lowercased) else { continue }
            let encodedBytes = lowercased[tokenRange].utf8.compactMap { byteEncoder[$0] }.joined()
            for token in bpe(encodedBytes).split(separator: " ") {
                if let tokenID = vocabulary[String(token)] { tokenIDs.append(tokenID) }
            }
        }
        tokenIDs = Array(tokenIDs.prefix(Self.contextLength - 2))

        let output = try MLMultiArray(shape: [1, NSNumber(value: Self.contextLength)], dataType: .int32)
        for index in 0..<Self.contextLength { output[index] = 0 }
        output[0] = NSNumber(value: startToken)
        for (index, tokenID) in tokenIDs.enumerated() {
            output[index + 1] = NSNumber(value: tokenID)
        }
        output[tokenIDs.count + 1] = NSNumber(value: endToken)
        return output
    }

    private func bpe(_ token: String) -> String {
        guard token.count > 1 else { return token + "</w>" }
        var word = token.map(String.init)
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            var bestPair: CLIPBytePair?
            var bestRank = Int.max
            for index in 0..<(word.count - 1) {
                let pair = CLIPBytePair(first: word[index], second: word[index + 1])
                if let rank = ranks[pair], rank < bestRank {
                    bestPair = pair
                    bestRank = rank
                }
            }
            guard let bestPair else { break }

            var merged: [String] = []
            var index = 0
            while index < word.count {
                if index + 1 < word.count,
                   word[index] == bestPair.first,
                   word[index + 1] == bestPair.second {
                    merged.append(bestPair.first + bestPair.second)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
        }
        return word.joined(separator: " ")
    }

    private static func makeByteEncoder() -> [UInt8: String] {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte)
            scalars.append(256 + extra)
            extra += 1
        }
        return Dictionary(uniqueKeysWithValues: zip(bytes, scalars).compactMap { byte, scalar in
            guard let unicode = UnicodeScalar(scalar) else { return nil }
            return (UInt8(byte), String(Character(unicode)))
        })
    }
}
