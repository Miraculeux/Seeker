import Foundation

enum FileNameMatcher {
    static func matches(_ value: String, query: String) -> Bool {
        guard query.contains("*") || query.contains("?") else {
            return value.localizedCaseInsensitiveContains(query)
        }

        let valueCharacters = Array(value.folding(options: [.caseInsensitive], locale: .current))
        let patternCharacters = Array(query.folding(options: [.caseInsensitive], locale: .current))
        var valueIndex = 0
        var patternIndex = 0
        var starIndex: Int?
        var retryValueIndex = 0

        while valueIndex < valueCharacters.count {
            if patternIndex < patternCharacters.count,
               patternCharacters[patternIndex] == "?"
                    || patternCharacters[patternIndex] == valueCharacters[valueIndex] {
                valueIndex += 1
                patternIndex += 1
            } else if patternIndex < patternCharacters.count,
                      patternCharacters[patternIndex] == "*" {
                starIndex = patternIndex
                patternIndex += 1
                retryValueIndex = valueIndex
            } else if let starIndex {
                patternIndex = starIndex + 1
                retryValueIndex += 1
                valueIndex = retryValueIndex
            } else {
                return false
            }
        }

        while patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternCharacters.count
    }
}
