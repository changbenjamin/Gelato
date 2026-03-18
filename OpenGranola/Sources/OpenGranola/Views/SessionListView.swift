import SwiftUI

/// Sidebar view showing all sessions grouped by date.
struct SessionListView: View {
    let listModel: SessionListModel
    @Binding var selectedSession: SessionSummary?
    let isRunning: Bool
    let liveTitle: String
    let liveWordCount: Int
    let onStartSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Gelato")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                if !isRunning {
                    Button {
                        onStartSession()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("New Note")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentTeal.opacity(0.1))
                        .foregroundStyle(Color.accentTeal)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Session list
            if listModel.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                List(selection: $selectedSession) {
                    // Live session card
                    if isRunning {
                        Button {
                            selectedSession = nil // shows live view in detail
                        } label: {
                            liveSessionRow
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(Color.green.opacity(0.06))
                    }

                    // Past sessions grouped by date
                    if listModel.sessions.isEmpty && !isRunning {
                        emptyState
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(listModel.groupedSessions, id: \.date) { group in
                            Section(group.date) {
                                ForEach(group.sessions) { session in
                                    SessionRow(session: session)
                                        .tag(session)
                                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
    }

    // MARK: - Components

    private var liveSessionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(liveTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Recording")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }

                if liveWordCount > 0 {
                    Text("· \(formatWordCount(liveWordCount))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 40)
            Image(systemName: "waveform")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.quaternary)
            Text("No sessions yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Tap New Note to start.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A single row in the session list sidebar.
struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.metadata.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 4) {
                Text(formattedDate)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                if session.metadata.wordCount > 0 {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                    Text(formatWordCount(session.metadata.wordCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var formattedDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy"
        return fmt.string(from: session.metadata.createdAt)
    }
}

/// Format word count with commas and proper singular/plural.
func formatWordCount(_ count: Int) -> String {
    let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    return "\(formatted) \(count == 1 ? "word" : "words")"
}
