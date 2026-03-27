import SwiftUI

/// Sidebar view showing all sessions grouped by date.
struct SessionListView: View {
    let listModel: SessionListModel
    @Binding var selectedSession: SessionSummary?
    let isRunning: Bool
    let liveTitle: String
    let liveStartTime: Date?
    let onStartSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Gelato")
                    .font(.gelatoSerif(size: 20, weight: .semibold))
                    .foregroundStyle(Color.warmTextPrimary)

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
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Color.warmCardBg)
                        .foregroundStyle(Color.warmTextPrimary)
                        .overlay {
                            Capsule()
                                .stroke(Color.warmBorder, lineWidth: 1)
                        }
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()
                .overlay(Color.warmBorder)

            if listModel.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if isRunning {
                            Button {
                                selectedSession = nil
                            } label: {
                                liveSessionRow(isSelected: selectedSession == nil)
                            }
                            .buttonStyle(.plain)
                        }

                        if listModel.sessions.isEmpty && !isRunning {
                            emptyState
                        } else {
                            ForEach(listModel.groupedSessions, id: \.date) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.date)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.warmTextMuted)
                                        .padding(.horizontal, 18)
                                        .padding(.bottom, 2)

                                    ForEach(group.sessions) { session in
                                        Button {
                                            selectedSession = session
                                        } label: {
                                            SessionRow(
                                                session: session,
                                                isSelected: selectedSession?.id == session.id
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 12)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 14)
                }
            }
        }
        .background(Color.warmSidebarBg)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.warmBorder.opacity(0.8))
                .frame(width: 1)
        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 300, max: 380)
    }

    // MARK: - Components

    private func liveSessionRow(isSelected: Bool) -> some View {
        SidebarRowContainer(isSelected: isSelected) {
            VStack(alignment: .leading, spacing: 4) {
                Text(liveTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.warmTextPrimary)
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

                    if let startTime = liveStartTime {
                        Text("· \(formatTime(startTime))")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.warmTextMuted)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 40)
            Image(systemName: "waveform")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.warmTextMuted.opacity(0.4))
            Text("No sessions yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.warmTextMuted)
            Text("Tap New Note to start.")
                .font(.system(size: 12))
                .foregroundStyle(Color.warmTextMuted.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }
}

/// A single row in the session list sidebar.
struct SessionRow: View {
    let session: SessionSummary
    let isSelected: Bool

    var body: some View {
        SidebarRowContainer(isSelected: isSelected) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.metadata.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.warmTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(formattedDate)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmTextMuted)

                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmTextMuted.opacity(0.5))
                    Text(formatTime(session.metadata.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmTextMuted)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var formattedDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy"
        return fmt.string(from: session.metadata.createdAt)
    }
}

private struct SidebarRowContainer<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isSelected ? Color.warmTextPrimary.opacity(0.55) : Color.clear)
                .frame(width: 2)

            content
                .padding(.leading, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(isSelected ? Color.warmSelectionBg.opacity(0.45) : Color.clear)
        .contentShape(Rectangle())
    }
}

/// Format a date as a time string like "2:30 PM".
func formatTime(_ date: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "h:mm a"
    return fmt.string(from: date)
}
