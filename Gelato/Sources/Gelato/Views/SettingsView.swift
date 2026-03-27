import SwiftUI
import CoreAudio
import Sparkle

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater?
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []

    var body: some View {
        Form {
            Section("Audio Input") {
                Picker("Microphone", selection: $settings.inputDeviceID) {
                    Text("Automatic (Recommended)").tag(AudioDeviceID(0))
                    ForEach(inputDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .font(.system(size: 12))

                if settings.inputDeviceID == 0,
                   let resolvedName = MicCapture.automaticInputDeviceName() {
                    Text("Currently using \(resolvedName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Transcription") {
                Picker("Mode", selection: $settings.transcriptionMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .font(.system(size: 12))

                TextField("Locale (e.g. en-US)", text: $settings.transcriptionLocale)
                    .font(.system(size: 12, design: .monospaced))

                Text(settings.transcriptionMode.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("API Keys") {
                Text("OpenAI credentials are loaded from `.env`, not Keychain.")
                    .font(.system(size: 12))
                Text("Current app config path: ~/Library/Application Support/Gelato/.env")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Set `OPENAI_API_KEY` to enable diarized transcript replacement and automatic notes.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("After editing `.env`, relaunch Gelato to pick up changes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing and screenshots", isOn: $settings.hideFromScreenShare)
                    .font(.system(size: 12))
                Text("This uses macOS capture protection, so it also disables screenshots while enabled.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let updater {
                Section("Updates") {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    .font(.system(size: 12))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 350)
        .onAppear {
            inputDevices = MicCapture.availableInputDevices()
        }
    }
}
