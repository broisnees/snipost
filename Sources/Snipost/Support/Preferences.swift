import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let snipostHotkeysChanged = Notification.Name("snipostHotkeysChanged")
}

/// Everything a global shortcut can trigger. `plainArea` is the "just snip and
/// copy" flow: raw screenshot straight to the clipboard, no beautify, no editor.
enum HotkeyAction: String, CaseIterable {
    case area
    case window
    case screen
    case plainArea
    case scrolling
    case ocrArea

    var title: String {
        switch self {
        case .area: return "Capture area"
        case .window: return "Capture window"
        case .screen: return "Capture full screen"
        case .plainArea: return "Snip to clipboard (plain)"
        case .scrolling: return "Scrolling capture"
        case .ocrArea: return "OCR snip (copy text)"
        }
    }

    var captureKind: CaptureKind {
        CaptureKind(rawValue: rawValue) ?? .area
    }
}

/// What happens right after a capture.
enum CaptureFlow: String, CaseIterable, Identifiable {
    case editor
    case thumbnail
    case instant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return "Open editor"
        case .thumbnail: return "Floating thumbnail"
        case .instant: return "Instant (no UI)"
        }
    }
}

/// User settings, persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var captureFlow: CaptureFlow {
        didSet { defaults.set(captureFlow.rawValue, forKey: "captureFlow") }
    }
    @Published var autoCopy: Bool {
        didSet { defaults.set(autoCopy, forKey: "autoCopy") }
    }
    @Published var autoSaveToDesktop: Bool {
        didSet { defaults.set(autoSaveToDesktop, forKey: "autoSaveToDesktop") }
    }
    @Published var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: "saveHistory") }
    }
    /// Burn the real system cursor (live position and shape — hand, I-beam…)
    /// into captures.
    @Published var includeCursor: Bool {
        didSet { defaults.set(includeCursor, forKey: "includeCursor") }
    }
    /// Where cmd-S and auto-save put files. Empty means the Desktop.
    @Published var saveFolderPath: String {
        didSet { defaults.set(saveFolderPath, forKey: "saveFolderPath") }
    }
    @Published var autoUploadToDrive: Bool {
        didSet { defaults.set(autoUploadToDrive, forKey: "autoUploadToDrive") }
    }
    @Published var notifyOnDriveUpload: Bool {
        didSet { defaults.set(notifyOnDriveUpload, forKey: "notifyOnDriveUpload") }
    }

    /// First time Drive gets connected, turn sync + notifications on so
    /// "everything I snip lands in Drive" just works out of the box.
    func enableDriveSyncDefaultsOnce() {
        guard !defaults.bool(forKey: "didDefaultAutoUpload") else { return }
        defaults.set(true, forKey: "didDefaultAutoUpload")
        autoUploadToDrive = true
        notifyOnDriveUpload = true
        Notifier.requestPermissionIfNeeded()
    }
    @Published private(set) var hotkeys: [HotkeyAction: Hotkey] = [:]

    static let defaultHotkeys: [HotkeyAction: Hotkey] = [
        .area: Hotkey(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(optionKey | shiftKey)),
        .window: Hotkey(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: UInt32(optionKey | shiftKey)),
        .screen: Hotkey(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(optionKey | shiftKey)),
        .plainArea: Hotkey(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(optionKey | shiftKey)),
        .scrolling: Hotkey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(optionKey | shiftKey)),
        .ocrArea: Hotkey(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(optionKey | shiftKey)),
    ]

    private init() {
        if let raw = defaults.string(forKey: "captureFlow"), let flow = CaptureFlow(rawValue: raw) {
            captureFlow = flow
        } else if defaults.object(forKey: "openEditorAfterCapture") as? Bool == false {
            captureFlow = .instant // migrate the old toggle
        } else {
            captureFlow = .editor
        }
        autoCopy = defaults.object(forKey: "autoCopy") as? Bool ?? true
        autoSaveToDesktop = defaults.object(forKey: "autoSaveToDesktop") as? Bool ?? false
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        includeCursor = defaults.object(forKey: "includeCursor") as? Bool ?? true
        saveFolderPath = defaults.string(forKey: "saveFolderPath") ?? ""
        autoUploadToDrive = defaults.object(forKey: "autoUploadToDrive") as? Bool ?? false
        notifyOnDriveUpload = defaults.object(forKey: "notifyOnDriveUpload") as? Bool ?? true

        var loaded: [HotkeyAction: Hotkey] = [:]
        for action in HotkeyAction.allCases {
            if let stored = defaults.array(forKey: "hotkey.\(action.rawValue)") as? [Int], stored.count == 2 {
                loaded[action] = Hotkey(keyCode: UInt32(stored[0]), carbonModifiers: UInt32(stored[1]))
            }
        }
        hotkeys = loaded
    }

    /// The folder captures are written to, falling back to the Desktop.
    var saveFolder: URL {
        if !saveFolderPath.isEmpty {
            return URL(fileURLWithPath: saveFolderPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var saveFolderName: String {
        saveFolder.lastPathComponent
    }

    func hotkey(for action: HotkeyAction) -> Hotkey {
        hotkeys[action] ?? Self.defaultHotkeys[action]!
    }

    func setHotkey(_ hotkey: Hotkey, for action: HotkeyAction) {
        hotkeys[action] = hotkey
        defaults.set(
            [Int(hotkey.keyCode), Int(hotkey.carbonModifiers)],
            forKey: "hotkey.\(action.rawValue)"
        )
        NotificationCenter.default.post(name: .snipostHotkeysChanged, object: nil)
    }
}
