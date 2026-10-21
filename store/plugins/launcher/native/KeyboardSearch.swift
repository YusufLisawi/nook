import Foundation
enum KeyboardSearch {
    /// Subsequence matching, favoring contiguous words and word beginnings.
    static func score(_ query: String, in text: String) -> Int? {
        let query = Array(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).filter { !$0.isWhitespace })
        let text = Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        return score(query, in: text)
    }

    /// Prepared strings let the launcher reuse the palette matcher without folding 500 titles per keystroke.
    static func score(_ query: [Character], in text: [Character]) -> Int? {
        guard !query.isEmpty else { return 0 }
        var cursor = 0, score = 0, previous = -2
        for letter in query {
            guard let index = text.indices.dropFirst(cursor).first(where: { text[$0] == letter }) else { return nil }
            score += index == previous + 1 ? 12 : 1
            if index == 0 || !text[index - 1].isLetter { score += 8 }
            score -= index - cursor
            cursor = index + 1
            previous = index
        }
        return score
    }
}
