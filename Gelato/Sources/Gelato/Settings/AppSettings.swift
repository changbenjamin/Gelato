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

    /// Stored as the AudioDeviceID integer. 0 means "automatic microphone selection".
    var inputDeviceID: AudioDeviceID {
        didSet { UserDefaults.standard.set(Int(inputDeviceID), forKey: "inputDeviceID") }
    }

    /// When true, all app windows are hidden from screen sharing and screenshots.
    var hideFromScreenShare: Bool {
        didSet {
            UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare")
            applyScreenShareVisibility()
        }
    }

    let openAIAPIKey: String

    init() {
        let defaults = UserDefaults.standard
        let env = EnvLoader.load()
        self.transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        let storedMode = defaults.string(forKey: "transcriptionMode") ?? ""
        if storedMode == TranscriptionMode.legacyElevenLabsRawValue
            || storedMode == TranscriptionMode.legacyOpenAIDiarizeRawValue {
            self.transcriptionMode = .openAICleanup
        } else {
            self.transcriptionMode = TranscriptionMode(rawValue: storedMode) ?? .openAICleanup
        }
        self.inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        // Default to false so screenshots work unless the user explicitly opts in.
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self.hideFromScreenShare = false
        } else {
            self.hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }
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
