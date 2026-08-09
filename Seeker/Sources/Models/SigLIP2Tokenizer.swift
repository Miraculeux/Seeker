import Foundation
import CoreML

private struct SigLIP2BytePair: Hashable {
    let first: String
    let second: String
}

final class SigLIP2Tokenizer: SemanticTextTokenizer, @unchecked Sendable {
    static let contextLength = 64

    private struct TokenizerFile: Decodable {
        struct Model: Decodable {
            let vocab: [String: Int]
            let merges: [[String]]
        }
        let model: Model
    }

    private let vocabulary: [String: Int]
    private let ranks: [SigLIP2BytePair: Int]

    init(tokenizerURL: URL) throws {
        let data = try Data(contentsOf: tokenizerURL, options: .mappedIfSafe)
        let file = try JSONDecoder().decode(TokenizerFile.self, from: data)
        vocabulary = file.model.vocab

        var parsedRanks: [SigLIP2BytePair: Int] = [:]
        parsedRanks.reserveCapacity(file.model.merges.count)
        for (index, merge) in file.model.merges.enumerated() where merge.count == 2 {
            parsedRanks[SigLIP2BytePair(first: merge[0], second: merge[1])] = index
        }
        ranks = parsedRanks
    }

    func encode(_ text: String) throws -> MLMultiArray {
        var pieces: [String] = []
        let normalized = text.replacingOccurrences(of: " ", with: "▁")
        for character in normalized {
            let piece = String(character)
            if vocabulary[piece] != nil {
                pieces.append(piece)
            } else {
                pieces.append(contentsOf: piece.utf8.map { String(format: "<0x%02X>", $0) })
            }
        }

        while pieces.count > 1 {
            var bestPair: SigLIP2BytePair?
            var bestRank = Int.max
            for index in 0..<(pieces.count - 1) {
                let pair = SigLIP2BytePair(first: pieces[index], second: pieces[index + 1])
                if let rank = ranks[pair], rank < bestRank {
                    bestRank = rank
                    bestPair = pair
                }
            }
            guard let bestPair else { break }
            var mergedPieces: [String] = []
            mergedPieces.reserveCapacity(pieces.count)
            var index = 0
            while index < pieces.count {
                if index + 1 < pieces.count,
                   pieces[index] == bestPair.first,
                   pieces[index + 1] == bestPair.second {
                    mergedPieces.append(bestPair.first + bestPair.second)
                    index += 2
                } else {
                    mergedPieces.append(pieces[index])
                    index += 1
                }
            }
            pieces = mergedPieces
        }

        var tokenIDs = pieces.compactMap { vocabulary[$0] }
        tokenIDs = Array(tokenIDs.prefix(Self.contextLength - 1))
        tokenIDs.append(1)

        let output = try MLMultiArray(
            shape: [1, NSNumber(value: Self.contextLength)],
            dataType: .int32
        )
        for index in 0..<Self.contextLength {
            output[index] = NSNumber(value: index < tokenIDs.count ? tokenIDs[index] : 0)
        }
        return output
    }
}
