import Foundation
import Observation

@Observable
@MainActor
final class TranscriptStore {
    private(set) var utterances: [Utterance] = []
    var volatileYouText: String = ""
    var volatileThemText: String = ""

    func append(_ utterance: Utterance) {
        utterances.append(utterance)
    }

    func clear() {
        utterances.removeAll()
        volatileYouText = ""
        volatileThemText = ""
    }
}
