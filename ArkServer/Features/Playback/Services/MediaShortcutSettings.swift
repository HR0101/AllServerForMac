import Foundation
import SwiftUI

enum MediaShortcutSettings {
    static let versionKey = "mediaShortcut.settingsVersion"

    static func keys(for action: MediaShortcutAction) -> [MediaShortcutKey] {
        let storedValue = UserDefaults.standard.object(forKey: action.storageKey)

        if let rawValues = storedValue as? [String] {
            let keys = rawValues.map { MediaShortcutKey(rawValue: $0) }
            return keys.isEmpty ? action.defaultKeys : uniqueKeys(keys)
        }

        if let rawValue = storedValue as? String {
            return [MediaShortcutKey(rawValue: rawValue)]
        }

        return action.defaultKeys
    }

    static func matches(_ action: MediaShortcutAction, press: KeyPress) -> Bool {
        keys(for: action).contains { $0.matches(press) }
    }

    static func shortcutList(
        for actions: [MediaShortcutAction],
        extraItems: [(key: String, action: String)] = []
    ) -> [(key: String, action: String)] {
        actions.map { action in
            (keys(for: action).map(\.displayName).joined(separator: " / "), action.helpAction)
        } + extraItems
    }

    static func setKeys(_ keys: [MediaShortcutKey], for action: MediaShortcutAction) {
        let normalizedKeys = uniqueKeys(keys)
        let keysToSave = normalizedKeys.isEmpty ? action.defaultKeys : normalizedKeys
        UserDefaults.standard.set(keysToSave.map(\.rawValue), forKey: action.storageKey)
        bumpVersion()
    }

    static func addKey(_ key: MediaShortcutKey, for action: MediaShortcutAction) {
        var currentKeys = keys(for: action)
        guard !currentKeys.contains(key) else { return }
        currentKeys.append(key)
        setKeys(currentKeys, for: action)
    }

    static func removeKey(_ key: MediaShortcutKey, for action: MediaShortcutAction) {
        let currentKeys = keys(for: action)
        guard currentKeys.count > 1 else { return }
        setKeys(currentKeys.filter { $0 != key }, for: action)
    }

    static func resetDefaults() {
        for action in MediaShortcutAction.allCases {
            UserDefaults.standard.set(action.defaultKeys.map(\.rawValue), forKey: action.storageKey)
        }
        bumpVersion()
    }

    static func bumpVersion() {
        let current = UserDefaults.standard.integer(forKey: versionKey)
        UserDefaults.standard.set(current + 1, forKey: versionKey)
    }

    private static func uniqueKeys(_ keys: [MediaShortcutKey]) -> [MediaShortcutKey] {
        var seen: Set<MediaShortcutKey> = []
        var result: [MediaShortcutKey] = []
        for key in keys where !seen.contains(key) {
            seen.insert(key)
            result.append(key)
        }
        return result
    }
}
