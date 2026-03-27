import SwiftUI

struct TranscriptView: View {
    let utterances: [Utterance]
    let volatileYouText: String
    let volatileThemText: String
    var bottomContentPadding: CGFloat = 0

    private var displayedUtterances: [Utterance] {
        utterances.chronologicallySorted
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(displayedUtterances) { utterance in
                        UtteranceBubble(utterance: utterance)
                            .id(utterance.id)
                    }

                    // Volatile text
                    if !volatileYouText.isEmpty {
                        VolatileIndicator(text: volatileYouText, speaker: .you)
                            .id("volatile-you")
                    }

                    if !volatileThemText.isEmpty {
                        VolatileIndicator(text: volatileThemText, speaker: .them)
                            .id("volatile-them")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 18 + bottomContentPadding)
            }
            .background(Color.warmCanvasBg)
            .onChange(of: utterances.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = displayedUtterances.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: volatileYouText) {
                proxy.scrollTo("volatile-you", anchor: .bottom)
            }
            .onChange(of: volatileThemText) {
                proxy.scrollTo("volatile-them", anchor: .bottom)
            }
        }
    }
}

private struct UtteranceBubble: View {
    let utterance: Utterance

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(utterance.speaker == .you ? "You" : "Them")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(utterance.speaker == .you ? Color.youColor : Color.themColor)
                .frame(width: 42, alignment: .trailing)
                .padding(.top, 3)

            Text(utterance.text)
                .font(.system(size: 13))
                .foregroundStyle(Color.readingText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct VolatileIndicator: View {
    let text: String
    let speaker: Speaker

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(speaker == .you ? "You" : "Them")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(speaker == .you ? Color.youColor : Color.themColor)
                .frame(width: 42, alignment: .trailing)
                .padding(.top, 3)

            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.readingText.opacity(0.7))
                Circle()
                    .fill(speaker == .you ? Color.youColor : Color.themColor)
                    .frame(width: 4, height: 4)
                    .opacity(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(0.6)
    }
}
