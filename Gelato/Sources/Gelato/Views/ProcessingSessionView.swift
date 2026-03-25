import SwiftUI

struct ProcessingSessionView: View {
    let title: String
    let status: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("You can edit the session once processing finishes.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
