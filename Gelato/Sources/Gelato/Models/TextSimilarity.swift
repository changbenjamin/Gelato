import Foundation

enum TextSimilarity {
    static func normalizedWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func normalizedText(_ text: String) -> String {
        normalizedWords(in: text).joined(separator: " ")
    }

    static func jaccard(_ lhs: String, _ rhs: String) -> Double {
        let lhsWords = Set(normalizedWords(in: lhs))
        let rhsWords = Set(normalizedWords(in: rhs))

        guard !lhsWords.isEmpty || !rhsWords.isEmpty else {
            return 1
        }

        let intersection = lhsWords.intersection(rhsWords).count
        let union = lhsWords.union(rhsWords).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }
}
