import Foundation
import Observation

@Observable
@MainActor
final class TranscriptStore {
    private static let echoWindow: TimeInterval = 1.75
    private static let echoSimilarityThreshold = 0.78
    private static let echoMinimumWords = 4
    private static let echoMinimumCharacters = 20

    private(set) var utterances: [Utterance] = []
    var volatileYouText: String = ""
    var volatileThemText: String = ""

    @discardableResult
    func append(_ utterance: Utterance) -> Bool {
        if shouldSuppressAsEcho(utterance) {
            diagLog("[TRANSCRIPT-ECHO] suppressed \(utterance.speaker.rawValue): \(utterance.text.prefix(80))")
            return false
        }

        utterances.append(utterance)
        return true
    }

    func clear() {
        utterances.removeAll()
        volatileYouText = ""
        volatileThemText = ""
    }

    private func shouldSuppressAsEcho(_ candidate: Utterance) -> Bool {
        let normalizedCandidate = TextSimilarity.normalizedText(candidate.text)
        guard normalizedCandidate.count >= Self.echoMinimumCharacters,
              TextSimilarity.normalizedWords(in: normalizedCandidate).count >= Self.echoMinimumWords else {
            return false
        }

        for recent in utterances.reversed() {
            let delta = abs(candidate.timestamp.timeIntervalSince(recent.timestamp))
            if delta > Self.echoWindow { break }
            guard recent.speaker != candidate.speaker else { continue }

            let normalizedRecent = TextSimilarity.normalizedText(recent.text)
            guard normalizedRecent.count >= Self.echoMinimumCharacters else { continue }

            if normalizedCandidate.contains(normalizedRecent)
                || normalizedRecent.contains(normalizedCandidate)
                || TextSimilarity.jaccard(normalizedCandidate, normalizedRecent) >= Self.echoSimilarityThreshold {
                return true
            }
        }

        return false
    }
}
