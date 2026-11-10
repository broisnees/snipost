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
    case plainScreen
    case scrolling
    case ocrArea
    case record
    case watch
    case captureBar
    case lastArea

    var title: String {
        switch self {
        case .area: return "Capture area"
        case .window: return "Capture window"
        case .screen: return "Capture full screen"
        case .plainArea: return "Area to clipboard (plain)"
        case .plainScreen: return "Full screen to clipboard (plain)"
        case .scrolling: return "Scrolling capture"
        case .ocrArea: return "OCR snip (copy text)"
        case .record: return "Record screen region"
        case .watch: return "Watch region with AI"
        case .captureBar: return "Capture bar (all modes)"
        case .lastArea: return "Repeat last area"
        }
    }

    var captureKind: CaptureKind {
        if self == .plainScreen { return .screen }
        return CaptureKind(rawValue: rawValue) ?? .area
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
        case .instant: return "Clipboard only"
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
    /// Off: captures stay the raw, full-resolution screenshot; styling is
    /// applied only when the user opens the editor.
    @Published var beautifyByDefault: Bool {
        didSet { defaults.set(beautifyByDefault, forKey: "beautifyByDefault") }
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
    @Published var autoUploadToDrive: Bool {
        didSet { defaults.set(autoUploadToDrive, forKey: "autoUploadToDrive") }
    }
    @Published var notifyOnDriveUpload: Bool {
        didSet { defaults.set(notifyOnDriveUpload, forKey: "notifyOnDriveUpload") }
    }
    /// Snipost owns ⌘⇧3 / ⌘⇧4 / ⌃⌘⇧4 / ⌘⇧5 (macOS's own shortcuts get
    /// switched off while this is on).
    @Published var replaceSystemScreenshots: Bool {
        didSet { defaults.set(replaceSystemScreenshots, forKey: "replaceSystemScreenshots") }
    }
    /// Seconds between AI-watch samples.
    /// Self-timer before screenshots (0 = off).
    @Published var captureDelay: Int {
        didSet { defaults.set(captureDelay, forKey: "captureDelay") }
    }
    @Published var watchInterval: Double {
        didSet { defaults.set(watchInterval, forKey: "watchInterval") }
    }
    @Published var recordCursorClicks: Bool {
        didSet { defaults.set(recordCursorClicks, forKey: "recordCursorClicks") }
    }
    /// Which installed agent (or the API) powers Watch with AI.
    @Published var watchAgent: WatchAgent {
        didSet { defaults.set(watchAgent.rawValue, forKey: "watchAgent") }
    }
    @Published var autoCopyRecordings: Bool {
        didSet { defaults.set(autoCopyRecordings, forKey: "autoCopyRecordings") }
    }
    @Published var recordMicrophone: Bool {
        didSet { defaults.set(recordMicrophone, forKey: "recordMicrophone") }
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
        .record: Hotkey(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(optionKey | shiftKey)),
        .watch: Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey | shiftKey)),
        .plainScreen: Hotkey(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(optionKey | shiftKey)),
        .captureBar: Hotkey(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(optionKey | shiftKey)),
        .lastArea: Hotkey(keyCode: UInt32(kVK_ANSI_L), carbonModifiers: UInt32(optionKey | shiftKey)),
    ]

    /// The macOS screenshot combos Snipost answers to while
    /// `replaceSystemScreenshots` is on.
    static let systemHotkeys: [(Hotkey, HotkeyAction)] = [
        (Hotkey(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(cmdKey | shiftKey)), .screen),
        (Hotkey(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(cmdKey | shiftKey | controlKey)), .plainScreen),
        (Hotkey(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey | shiftKey)), .area),
        (Hotkey(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey | shiftKey | controlKey)), .plainArea),
        (Hotkey(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(cmdKey | shiftKey)), .captureBar),
    ]

    var anthropicAPIKey: String {
        get { Keychain.get("anthropicAPIKey") ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "" }
        set {
            Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "anthropicAPIKey")
            objectWillChange.send()
        }
    }

    private init() {
        if let raw = defaults.string(forKey: "captureFlow"), let flow = CaptureFlow(rawValue: raw) {
            captureFlow = flow
        } else if defaults.object(forKey: "openEditorAfterCapture") as? Bool == false {
            captureFlow = .instant // migrate the old toggle
        } else {
            captureFlow = .instant // clipboard only; edit later from Recent/History
        }
        autoCopy = defaults.object(forKey: "autoCopy") as? Bool ?? true
        beautifyByDefault = defaults.bool(forKey: "beautifyByDefault")
        autoSaveToDesktop = defaults.object(forKey: "autoSaveToDesktop") as? Bool ?? false
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        includeCursor = defaults.object(forKey: "includeCursor") as? Bool ?? true
        autoUploadToDrive = defaults.object(forKey: "autoUploadToDrive") as? Bool ?? false
        notifyOnDriveUpload = defaults.object(forKey: "notifyOnDriveUpload") as? Bool ?? true
        replaceSystemScreenshots = defaults.bool(forKey: "replaceSystemScreenshots")
        watchInterval = defaults.object(forKey: "watchInterval") as? Double ?? 5
        captureDelay = defaults.integer(forKey: "captureDelay")
        recordCursorClicks = defaults.object(forKey: "recordCursorClicks") as? Bool ?? true
        recordMicrophone = defaults.bool(forKey: "recordMicrophone")
        autoCopyRecordings = defaults.object(forKey: "autoCopyRecordings") as? Bool ?? true
        // Resolved against installed agents when a watch starts — probing the
        // login-shell PATH here would block launch.
        watchAgent = defaults.string(forKey: "watchAgent").flatMap(WatchAgent.init(rawValue:)) ?? .claude

        var loaded: [HotkeyAction: Hotkey] = [:]
        for action in HotkeyAction.allCases {
            if let stored = defaults.array(forKey: "hotkey.\(action.rawValue)") as? [Int], stored.count == 2 {
                loaded[action] = Hotkey(keyCode: UInt32(stored[0]), carbonModifiers: UInt32(stored[1]))
            }
        }
        hotkeys = loaded
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
