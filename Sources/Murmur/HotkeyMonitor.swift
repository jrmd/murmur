import AppKit
import ApplicationServices

/// Watches the keyboard for the dictation hotkey.
///
/// The primary path is a session event tap, which can swallow the hotkey so the focused app never sees it
/// (the Globe key would otherwise open the emoji picker, and a letter hotkey would type its character).
/// Without Accessibility permission the tap cannot be created, so we fall back to NSEvent monitors, which
/// observe but cannot consume — no worse than before the tap existed.
///
/// Main thread only: the tap callback runs on the main run loop, so `swallowing` and `onEscape` are read and
/// written there without locking.
final class HotkeyMonitor {
    private static let escapeKeyCode = 53
    /// Modifiers compared when matching `swallowing`; caps lock and the numeric pad must not break a match.
    private static let matchMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    private let handler: (_ isDown: Bool, _ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) -> Void
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitors: [Any] = []
    /// Last reported state per modifier key code. Left and right share one flag, so the flag alone cannot say
    /// which side was released while the other is still held.
    private var modifierDown: [Int: Bool] = [:]

    /// Key combos whose keyDown/keyUp are swallowed. Non-modifier hotkeys only: swallowing flagsChanged would
    /// leave the system's modifier state wrong. Main thread only.
    var swallowing: [(keyCode: Int, modifiers: NSEvent.ModifierFlags)] = []
    var onEscape: (() -> Void)?

    var isUsingEventTap: Bool { tap != nil }

    init(handler: @escaping (_ isDown: Bool, _ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) -> Void) {
        self.handler = handler
        // One path at a time, so no event is reported twice.
        if !startEventTap() { startMonitors() }
    }

    deinit {
        stopEventTap()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }

    // MARK: Modifier state

    /// The flag a modifier key code sets, or nil for ordinary keys.
    static func modifierFlag(for keyCode: Int) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 63: return .function
        case 54, 55: return .command
        case 58, 61: return .option
        case 59, 62: return .control
        case 56, 60: return .shift
        case 57: return .capsLock
        default: return nil
        }
    }

    /// Whether `keyCode` is down after a flagsChanged event carrying `flags`.
    ///
    /// A set flag only means "this key went down" when it was not already down: left and right share one flag,
    /// so a set flag on an already-down key means that side was released while the other still holds it.
    /// Caps lock is a toggle, so its flag is the state.
    static func isModifierDown(keyCode: Int, flags: NSEvent.ModifierFlags, previouslyDown: Bool) -> Bool {
        guard let flag = modifierFlag(for: keyCode), flags.contains(flag) else { return false }
        return keyCode == 57 || !previouslyDown
    }

    // MARK: Event tap

    private func startEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        // An active tap (not .listenOnly) is what allows returning nil to consume the event.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: hotkeyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopEventTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables a tap whose callback was slow or interrupted; without this the hotkey dies.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            modifierDown.removeAll() // events were missed while it was off
            return pass
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return pass
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(.deviceIndependentFlagsMask)
        let isDown: Bool
        switch type {
        case .flagsChanged:
            isDown = HotkeyMonitor.isModifierDown(keyCode: keyCode, flags: flags, previouslyDown: modifierDown[keyCode] ?? false)
            modifierDown[keyCode] = isDown
            // Forget keys whose flag is gone, so a missed event cannot leave a stale "down" behind.
            modifierDown = modifierDown.filter { !$0.value || flags.contains(HotkeyMonitor.modifierFlag(for: $0.key) ?? []) }
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return pass }
            isDown = true
        default:
            isDown = false
        }
        report(isDown: isDown, keyCode: keyCode, modifiers: flags)
        // Swallow ordinary keys only: a consumed flagsChanged would corrupt the system's modifier state.
        if type != .flagsChanged, isSwallowed(keyCode: keyCode, modifiers: flags) { return nil }
        return pass
    }

    // MARK: NSEvent fallback

    private func startMonitors() {
        let down: (NSEvent) -> Void = { [weak self] event in self?.handle(event: event, isDown: true) }
        let up: (NSEvent) -> Void = { [weak self] event in self?.handle(event: event, isDown: false) }
        let flags: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        let masks: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [(.keyDown, down), (.keyUp, up), (.flagsChanged, flags)]
        for (mask, body) in masks {
            if let token = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: body) { monitors.append(token) }
            if let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { body($0); return $0 }) { monitors.append(token) }
        }
    }

    private func handle(event: NSEvent, isDown: Bool) {
        guard !event.isARepeat else { return }
        report(isDown: isDown, keyCode: Int(event.keyCode), modifiers: event.modifierFlags)
    }

    private func handleFlags(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isDown = HotkeyMonitor.isModifierDown(keyCode: keyCode, flags: flags, previouslyDown: modifierDown[keyCode] ?? false)
        modifierDown[keyCode] = isDown
        report(isDown: isDown, keyCode: keyCode, modifiers: flags)
    }

    // MARK: Reporting

    private func report(isDown: Bool, keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        handler(isDown, keyCode, modifiers.intersection(.deviceIndependentFlagsMask))
        // Esc cancels whatever is running; it is never swallowed and needs no Murmur key held.
        if isDown, keyCode == Self.escapeKeyCode { onEscape?() }
    }

    private func isSwallowed(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        let actual = modifiers.intersection(Self.matchMask)
        return swallowing.contains { $0.keyCode == keyCode && $0.modifiers.intersection(Self.matchMask) == actual }
    }
}

/// C callback for the tap; `userInfo` carries the monitor unretained, so the tap must be invalidated before it dies.
private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handleTap(type: type, event: event)
}
