import AppKit
import Carbon.HIToolbox
import Observation

/// A key plus modifiers, stored as Carbon values because that is what
/// `RegisterEventHotKey` takes.
struct HotKeyCombo: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Ctrl+Opt+Cmd+C
    static let standard = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_C),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    /// "⌃⌥⌘C"
    var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.namedKeys[Int(keyCode)] ?? keyName.uppercased())
    }

    /// For showing the shortcut next to the menu item. Empty for keys that
    /// have no single character, such as F5.
    var menuKeyEquivalent: String {
        Self.namedKeys[Int(keyCode)] == nil && keyName.count == 1 ? keyName : ""
    }

    /// Keys whose name isn't the character they type.
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// The character this key produces on the current keyboard layout.
    private var keyName: String {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let layout = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let pointer = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                pointer, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length)
    }
}

extension HotKeyCombo {
    /// The combination in a key-down event, or nil when it has none of ⌃, ⌥
    /// and ⌘. A shortcut without one of those would swallow ordinary typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        guard modifiers != 0 else { return nil }
        if flags.contains(.shift) { modifiers |= shiftKey }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: UInt32(modifiers))
    }
}

/// A system-wide shortcut registered with Carbon's `RegisterEventHotKey`.
/// Unlike an event tap this needs no Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var dispatcherInstalled = false

    private let id: UInt32
    private var reference: EventHotKeyRef?

    /// Returns nil when the combination can't be registered, which usually
    /// means another app already owns it.
    init?(combo: HotKeyCombo, handler: @escaping () -> Void) {
        Self.installDispatcher()
        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: 0x5348_4343 /* 'SHCC' */, id: id)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, reference != nil else { return nil }
        Self.handlers[id] = handler
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.handlers[id] = nil
    }

    /// One Carbon handler serves every hotkey and looks the callback up by ID.
    private static func installDispatcher() {
        guard !dispatcherInstalled else { return }
        dispatcherInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { HotKey.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Owns the capture shortcut: registers it at launch, swaps it when the user
/// records a new one, and steps aside while a new one is being recorded.
@Observable
final class HotKeyCenter {
    private(set) var combo: HotKeyCombo
    /// False when another app holds the combination.
    private(set) var isRegistered = false

    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        combo = Preferences.hotKey
        register()
    }

    /// Switches to a new combination and saves it. Returns false, keeping the
    /// current one, when the new one can't be registered.
    @discardableResult
    func change(to new: HotKeyCombo) -> Bool {
        hotKey?.unregister()
        guard let registered = HotKey(combo: new, handler: handler) else {
            register()
            return false
        }
        hotKey = registered
        combo = new
        isRegistered = true
        Preferences.hotKey = new
        return true
    }

    /// While a shortcut is being recorded, the current one must reach the
    /// recorder instead of starting a capture.
    func suspend() {
        hotKey?.unregister()
        hotKey = nil
    }

    func resume() {
        if hotKey == nil { register() }
    }

    private func register() {
        hotKey = HotKey(combo: combo, handler: handler)
        isRegistered = hotKey != nil
    }
}
