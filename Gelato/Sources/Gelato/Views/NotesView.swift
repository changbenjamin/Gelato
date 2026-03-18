import SwiftUI

/// Editable free-form notes for a session, with debounced auto-save.
struct NotesView: View {
    let sessionID: String
    let library: SessionLibrary

    @State private var text: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var isLoaded = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            if text.isEmpty && !isFocused {
                Text("Add notes...")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 25)
                    .padding(.vertical, 20)
                    .allowsHitTesting(false)
            }
        }
        .task {
            let loaded = await library.loadNotes(for: sessionID)
            text = loaded
            isLoaded = true
        }
        .onChange(of: text) {
            guard isLoaded else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await library.saveNotes(for: sessionID, text: text)
            }
        }
    }
}
