import AppKit
import ServiceManagement

/// Turns macOS's own screenshot shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5 and the ⌃ clipboard
/// variants) off or back on — the same switches as System Settings →
/// Keyboard → Keyboard Shortcuts → Screenshots. While they're off, the
/// WindowServer stops swallowing those combos and Snipost's hotkeys get them.
enum SystemShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString

    /// Symbolic-hotkey IDs with their stock bindings: (ASCII char, keycode, modifier mask).
    private static let screenshotHotkeys: [Int: (Int, Int, Int)] = [
        28: (51, 20, 1_179_648),   // ⌘⇧3  save screen
        29: (51, 20, 1_441_792),   // ⌃⌘⇧3 screen to clipboard
        30: (52, 21, 1_179_648),   // ⌘⇧4  save area
        31: (52, 21, 1_441_792),   // ⌃⌘⇧4 area to clipboard
        184: (53, 23, 1_179_648),  // ⌘⇧5  screenshot & recording options
    ]

    /// True when every macOS screenshot shortcut is currently disabled.
    static var systemShortcutsDisabled: Bool {
        let all = currentDict()
        return screenshotHotkeys.keys.allSatisfy { id in
            ((all[String(id)] as? [String: Any])?["enabled"] as? Bool) == false
        }
    }

    /// Enables or disables the macOS screenshot shortcuts. Returns false if
    /// the preference couldn't be written.
    @discardableResult
    static func setSystemShortcutsEnabled(_ enabled: Bool) -> Bool {
        var all = currentDict()
        for (id, binding) in screenshotHotkeys {
            var entry = all[String(id)] as? [String: Any] ?? [
                "value": [
                    "parameters": [binding.0, binding.1, binding.2],
                    "type": "standard",
                ] as [String: Any],
            ]
            entry["enabled"] = enabled
            all[String(id)] = entry
        }
        CFPreferencesSetValue(key, all as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return false }
        applyNow()
        return true
    }

    private static func currentDict() -> [String: Any] {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    /// Makes the WindowServer re-read symbolic hotkeys without a log-out.
    private static func applyNow() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-u"]
        try? process.run()
    }

    static func openKeyboardShortcutsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Launch at login via the modern login-item API (bundled app only).
@MainActor
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool {
        isAvailable && SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Toast.show("Couldn't change login item: \(error.localizedDescription)")
        }
    }
}
