import Foundation
import Security
import ApplicationServices
import CoreGraphics

// MARK: - Keychain

/// Stores the Anthropic API key in the macOS Keychain.
/// Falls back to the ANTHROPIC_API_KEY environment variable for development.
enum KeychainStore {
    private static let service = "app.nudgeagent.NudgeAgent"
    private static let account = "anthropic-api-key"

    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        return nil
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Permissions

enum Permissions {
    /// Accessibility, needed for window titles and the Firefox address bar.
    static func accessibilityGranted(prompt: Bool = false) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Screen Recording, needed for screenshots.
    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}

// MARK: - Local storage

/// Small JSON files in ~/Library/Application Support/NudgeAgent. Never stores screenshots or page content.
enum LocalStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NudgeAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        let url = directory.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to file: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(file), options: .atomic)
    }

    /// Append one JSON line (session log). When `maxBytes` is set and the file is larger,
    /// it is rotated to "<file>.1" (replacing an older rotation) before appending.
    static func appendLine<T: Encodable>(_ value: T, to file: String, maxBytes: Int? = nil) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        let url = directory.appendingPathComponent(file)
        if let maxBytes,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxBytes {
            let rotated = directory.appendingPathComponent(file + ".1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
