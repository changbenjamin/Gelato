import SwiftUI
import CoreAudio

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []

    var body: some View {
        Form {
            Section("Knowledge Base") {
                HStack {
                    Text(settings.kbFolderPath.isEmpty ? "No folder selected" : settings.kbFolderPath)
                        .font(.system(size: 12))
                        .foregroundStyle(settings.kbFolderPath.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Choose...") {
                        chooseFolder()
                    }
                }
            }

            Section("Voyage AI") {
                SecureField("API Key", text: $settings.voyageApiKey)
                .font(.system(size: 12, design: .monospaced))
            }

            Section("OpenRouter API") {
                SecureField("API Key", text: $settings.openRouterApiKey)
                .font(.system(size: 12, design: .monospaced))

                TextField("Model", text: $settings.selectedModel, prompt: Text("e.g. google/gemini-3-flash-preview"))
                    .font(.system(size: 12, design: .monospaced))
            }

            Section("Audio Input") {
                Picker("Microphone", selection: $settings.inputDeviceID) {
                    Text("System Default").tag(AudioDeviceID(0))
                    ForEach(inputDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .font(.system(size: 12))
            }

            Section("Transcription") {
                TextField("Locale (e.g. en-US)", text: $settings.transcriptionLocale)
                    .font(.system(size: 12, design: .monospaced))
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                    .font(.system(size: 12))
                Text("When enabled, the app is invisible during screen sharing and recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
}
        .formStyle(.grouped)
        .frame(width: 450, height: 400)
        .onAppear {
            inputDevices = MicCapture.availableInputDevices()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing your knowledge base documents (.md, .txt)"

        if panel.runModal() == .OK, let url = panel.url {
            settings.kbFolderPath = url.path
        }
    }
}
