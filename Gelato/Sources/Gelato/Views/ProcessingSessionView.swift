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
                .font(.gelatoSerif(size: 28, weight: .semibold))
                .foregroundStyle(Color.warmTextPrimary)
            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(Color.warmTextSecondary)
            Text("You can edit the session once processing finishes.")
                .font(.system(size: 12))
                .foregroundStyle(Color.warmTextMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.warmBackground)
    }
}
