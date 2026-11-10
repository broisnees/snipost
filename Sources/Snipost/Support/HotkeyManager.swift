import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Global hotkeys. Preferred backend is a CGEvent tap (needs Accessibility):
/// unlike Carbon's RegisterEventHotKey, a tap sees keystrokes upstream of menu
/// tracking, so shortcuts keep working while menus are open — and lets us
/// freeze the screen *with the menu still visible* before dismissing it.
/// Falls back to Carbon when Accessibility isn't granted.
@MainActor
final class HotkeyManager {
    typealias Handler = () -> Void

    private struct Binding {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let handler: Handler
    }

    private var bindings: [Binding] = []
    private var tap: HotkeyTap?

    // Carbon fallback plumbing
    private var handlers: [UInt32: Handler] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {
        installCarbonHandler()
        if AXIsProcessTrusted() {
            tap = HotkeyTap { [weak self] index in
                self?.fire(index)
            }
        }
    }

    func unregisterAll() {
        bindings.removeAll()
        tap?.setCombos([])
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        handlers.removeAll()
    }

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping Handler) {
        bindings.append(Binding(keyCode: keyCode, carbonModifiers: modifiers, handler: handler))
        if let tap {
            tap.setCombos(bindings.map { (Int64($0.keyCode), Self.cgFlags(from: $0.carbonModifiers)) })
        } else {
            registerCarbon(keyCode: keyCode, modifiers: modifiers, handler: handler)
        }
    }

    private func fire(_ index: Int) {
        guard bindings.indices.contains(index) else { return }
        bindings[index].handler()
    }

    private static func cgFlags(from carbon: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        return flags
    }

    // MARK: Carbon fallback

    private func installCarbonHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    manager.handlers[hotKeyID.id]?()
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func registerCarbon(keyCode: UInt32, modifiers: UInt32, handler: @escaping Handler) {
        let id = nextID
        nextID += 1
        handlers[id] = handler

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4950), id: id) // 'SNIP'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }
}

/// A display frame frozen by the hotkey tap *before* an open menu was
/// dismissed — CaptureService prefers it so open menus appear in area snips.
@MainActor
enum PendingFrozenFrame {
    private static var stored: (image: CGImage, displayID: CGDirectDisplayID, timestamp: Date)?

    static func store(_ image: CGImage, displayID: CGDirectDisplayID) {
        stored = (image, displayID, Date())
    }

    static func clear() { stored = nil }

    static func consume(displayID: CGDirectDisplayID) -> CGImage? {
        defer { stored = nil }
        guard let stored,
              stored.displayID == displayID,
              Date().timeIntervalSince(stored.timestamp) < 3
        else { return nil }
        return stored.image
    }
}

private final class WeakTapBox {
    weak var tap: HotkeyTap?
}

/// Session-level keyboard tap on its own thread, so shortcuts fire even while
/// the app's main thread is busy tracking its own menu.
private final class HotkeyTap {
    private let lock = NSLock()
    private var combos: [(keyCode: Int64, flags: CGEventFlags)] = []
    private let deliver: @MainActor (Int) -> Void
    private var tapPort: CFMachPort?

    init?(deliver: @escaping @MainActor (Int) -> Void) {
        self.deliver = deliver

        // Create the tap synchronously so a failure (no Accessibility, or it
        // was revoked) returns nil and the Carbon fallback takes over instead
        // of leaving every hotkey dead.
        let box = WeakTapBox()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo,
                      let tapSelf = Unmanaged<WeakTapBox>.fromOpaque(userInfo).takeUnretainedValue().tap
                else { return Unmanaged.passUnretained(event) }
                return tapSelf.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passRetained(box).toOpaque()
        ) else { return nil }
        tapPort = tap
        box.tap = self

        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "SnipostHotkeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func setCombos(_ combos: [(Int64, CGEventFlags)]) {
        lock.lock()
        self.combos = combos.map { (keyCode: $0.0, flags: $0.1) }
        lock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])

        lock.lock()
        let current = combos
        lock.unlock()

        guard let index = current.firstIndex(where: { $0.keyCode == keyCode && $0.flags == flags }) else {
            return Unmanaged.passUnretained(event)
        }
        // Holding the combo: swallow key repeats instead of opening several overlays.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        dispatchMatch(index)
        return nil // consume the shortcut
    }

    private func dispatchMatch(_ index: Int) {
        let deliver = deliver
        if Self.isMenuTrackingActive() {
            // Freeze the screen with the menu still visible, then dismiss it
            // so clicks reach the selection overlay.
            let includeCursor = UserDefaults.standard.object(forKey: "includeCursor") as? Bool ?? true
            Task.detached(priority: .userInitiated) {
                if let frozen = try? await CaptureService.freezeDisplayUnderMouse(showsCursor: includeCursor) {
                    await MainActor.run {
                        PendingFrozenFrame.store(frozen.image, displayID: frozen.displayID)
                    }
                }
                Self.postEscape()
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run { deliver(index) }
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(index) }
            }
        }
    }

    /// Any open menu (menu bar, status item, context menu) has a window at
    /// the pop-up-menu level.
    private static func isMenuTrackingActive() -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return info.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }

    private static func postEscape() {
        let escape = CGKeyCode(53)
        CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
