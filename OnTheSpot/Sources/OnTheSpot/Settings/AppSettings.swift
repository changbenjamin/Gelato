import AppKit
import Foundation
import Observation
import Security
import CoreAudio

@Observable
@MainActor
final class AppSettings {
    var kbFolderPath: String {
        didSet { UserDefaults.standard.set(kbFolderPath, forKey: "kbFolderPath") }
    }

    var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    var transcriptionLocale: String {
        didSet { UserDefaults.standard.set(transcriptionLocale, forKey: "transcriptionLocale") }
    }

    /// Stored as the AudioDeviceID integer. 0 means "use system default".
    var inputDeviceID: AudioDeviceID {
        didSet { UserDefaults.standard.set(Int(inputDeviceID), forKey: "inputDeviceID") }
    }

    var openRouterApiKey: String {
        didSet { KeychainHelper.save(key: "openRouterApiKey", value: openRouterApiKey) }
    }

    var voyageApiKey: String {
        didSet { KeychainHelper.save(key: "voyageApiKey", value: voyageApiKey) }
    }

    /// When true, all app windows are invisible to screen sharing / recording.
    var hideFromScreenShare: Bool {
        didSet {
            UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare")
            applyScreenShareVisibility()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.kbFolderPath = defaults.string(forKey: "kbFolderPath") ?? ""
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? "anthropic/claude-sonnet-4"
        self.transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self.inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self.openRouterApiKey = KeychainHelper.load(key: "openRouterApiKey") ?? ""
        self.voyageApiKey = KeychainHelper.load(key: "voyageApiKey") ?? ""
        // Default to true (hidden) if key has never been set
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self.hideFromScreenShare = true
        } else {
            self.hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }
    }

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    var kbFolderURL: URL? {
        guard !kbFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: kbFolderPath)
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }

}

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.onthespot.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
