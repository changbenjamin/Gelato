import AppKit
import Foundation
import Observation
import CoreAudio

@Observable
@MainActor
final class AppSettings {
    var transcriptionLocale: String {
        didSet { UserDefaults.standard.set(transcriptionLocale, forKey: "transcriptionLocale") }
    }

    var transcriptionMode: TranscriptionMode {
        didSet { UserDefaults.standard.set(transcriptionMode.rawValue, forKey: "transcriptionMode") }
    }

    /// Stored as the AudioDeviceID integer. 0 means "use system default".
    var inputDeviceID: AudioDeviceID {
        didSet { UserDefaults.standard.set(Int(inputDeviceID), forKey: "inputDeviceID") }
    }

    /// When true, all app windows are invisible to screen sharing / recording.
    var hideFromScreenShare: Bool {
        didSet {
            UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare")
            applyScreenShareVisibility()
        }
    }

    let elevenLabsAPIKey: String
    let openAIAPIKey: String

    init() {
        let defaults = UserDefaults.standard
        let env = EnvLoader.load()
        self.transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self.transcriptionMode = TranscriptionMode(
            rawValue: defaults.string(forKey: "transcriptionMode") ?? ""
        ) ?? .parakeet
        self.inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        // Default to true (hidden) if key has never been set
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self.hideFromScreenShare = true
        } else {
            self.hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }
        self.elevenLabsAPIKey = env["ELEVENLABS_API_KEY"] ?? ""
        self.openAIAPIKey = env["OPENAI_API_KEY"] ?? ""
    }

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }
}
