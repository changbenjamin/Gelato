import SwiftUI
import CoreAudio
import Sparkle

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []

    var body: some View {
        Form {
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
                Text("Keys are loaded from `.env`, not Keychain.")
                    .font(.system(size: 12))
                Text("Current app config path: ~/Library/Application Support/Gelato/.env")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("After editing `.env`, relaunch Gelato to pick up changes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                    .font(.system(size: 12))
                Text("When enabled, the app is invisible during screen sharing and recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .font(.system(size: 12))
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 350)
        .onAppear {
            inputDevices = MicCapture.availableInputDevices()
        }
    }
}
