import Foundation
import Observation

/// Observable bridge between SessionLibrary (actor) and SwiftUI views.
@Observable
@MainActor
final class SessionListModel {
    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private let library: SessionLibrary

    init(library: SessionLibrary) {
        self.library = library
    }

    /// Grouped sessions by date for the list view.
    var groupedSessions: [(date: String, sessions: [SessionSummary])] {
        let calendar = Calendar.current
        let now = Date()

        var groups: [String: [SessionSummary]] = [:]
        var groupOrder: [String] = []

        for session in sessions {
            let date = session.metadata.createdAt
            let label: String
            if calendar.isDateInToday(date) {
                label = "Today"
            } else if calendar.isDateInYesterday(date) {
                label = "Yesterday"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                let fmt = DateFormatter()
                fmt.dateFormat = "EEEE"  // e.g. "Monday"
                label = fmt.string(from: date)
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "EEE, MMM d"  // e.g. "Mon, Mar 2"
                label = fmt.string(from: date)
            }

            if groups[label] == nil {
                groupOrder.append(label)
            }
            groups[label, default: []].append(session)
        }

        return groupOrder.map { label in
            (date: label, sessions: groups[label] ?? [])
        }
    }

    /// Load all sessions from disk.
    func load() async {
        isLoading = true
        let loaded = await library.loadSessions()
        sessions = loaded
        isLoading = false
    }

    /// Update a session title.
    func updateTitle(sessionID: String, newTitle: String) async {
        await library.updateTitle(for: sessionID, newTitle: newTitle)
        // Reload entire array to guarantee @Observable triggers a UI refresh
        let reloaded = await library.loadSessions()
        sessions = reloaded
    }

    /// Refresh the session list (e.g. after a session ends).
    func refresh() async {
        let loaded = await library.loadSessions()
        sessions = loaded
    }
}
