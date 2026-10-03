import AppKit
import Carbon
import Foundation

private let wizardscrollHotKeySignature: OSType = 0x575A5343 // WZSC
private let wizardscrollHotKeyID: UInt32 = 1

private func wizardscrollHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == wizardscrollHotKeySignature,
          hotKeyID.id == wizardscrollHotKeyID,
          let userData else { return OSStatus(eventNotHandledErr) }

    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    hotKey.fire(isPressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
    return noErr
}

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var modifierMonitors: [Any] = []
    private var modifierKey: ModifierKey?

    /// `onCancel` fires only for a modifier-only shortcut, when it turns out
    /// to be part of a key combination, such as ⌥ typing a special character.
    /// No release follows a cancel.
    func register(
        _ shortcut: DictationShortcut,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) throws {
        unregister()
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel

        if shortcut.isModifierOnly {
            registerModifierKey(shortcut)
            return
        }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            wizardscrollHotKeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else { throw HotKeyError.registrationFailed(handlerStatus) }

        let identifier = EventHotKeyID(signature: wizardscrollHotKeySignature, id: wizardscrollHotKeyID)
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            unregister()
            throw registrationStatus == OSStatus(eventHotKeyExistsErr)
                ? HotKeyError.alreadyInUse
                : HotKeyError.registrationFailed(registrationStatus)
        }
    }

    /// Carbon hot keys need a non-modifier key, so a lone modifier is watched
    /// through event monitors instead. The global monitor sees other apps'
    /// events only with Accessibility access; the local one covers this app.
    private func registerModifierKey(_ shortcut: DictationShortcut) {
        modifierKey = ModifierKey(shortcut: shortcut)
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleModifierEvent(event)
        }) {
            modifierMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleModifierEvent(event)
            return event
        }) {
            modifierMonitors.append(local)
        }
    }

    private func handleModifierEvent(_ event: NSEvent) {
        guard var key = modifierKey else { return }
        defer { modifierKey = key }

        guard event.type == .flagsChanged, UInt32(event.keyCode) == key.shortcut.keyCode else {
            // Any other key, modifier or click while the shortcut is down makes
            // it part of a combination rather than the shortcut.
            if key.isDown, !key.isCombined {
                key.isCombined = true
                onCancel?()
            }
            return
        }

        let isDown = key.shortcut.isModifierKeyDown(in: event)
        guard isDown != key.isDown else { return }
        key.isDown = isDown
        if isDown {
            key.isCombined = false
            onPress?()
        } else if !key.isCombined {
            onRelease?()
        }
    }

    fileprivate func fire(isPressed: Bool) {
        isPressed ? onPress?() : onRelease?()
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        modifierMonitors.forEach(NSEvent.removeMonitor)
        hotKeyRef = nil
        eventHandlerRef = nil
        modifierMonitors = []
        modifierKey = nil
        onPress = nil
        onRelease = nil
        onCancel = nil
    }

    deinit { unregister() }
}

/// The state of a modifier key used as a shortcut on its own.
private struct ModifierKey {
    let shortcut: DictationShortcut
    var isDown = false
    var isCombined = false
}

enum HotKeyError: LocalizedError {
    case alreadyInUse
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyInUse: "Another app is already using this shortcut"
        case .registrationFailed(let status): "Global shortcut registration failed (\(status))"
        }
    }
}

extension DictationShortcut {
    private static let functionKeyCodes: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]

    private static let namedKeyCodes: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟"
    ]

    /// The modifier the key sets, for a modifier-only shortcut.
    var modifierFlag: NSEvent.ModifierFlags {
        switch Int(keyCode) {
        case kVK_RightOption: .option
        case kVK_RightCommand: .command
        case kVK_RightControl: .control
        case kVK_RightShift: .shift
        default: []
        }
    }

    /// Whether a modifier-only shortcut's own key is down. The device-dependent
    /// flags tell the sides apart, which `modifierFlag` cannot while the left
    /// key is also held. The masks are `NX_DEVICER*KEYMASK` from IOLLEvent.h.
    func isModifierKeyDown(in event: NSEvent) -> Bool {
        let deviceMask: UInt = switch Int(keyCode) {
        case kVK_RightOption: 0x40
        case kVK_RightCommand: 0x10
        case kVK_RightControl: 0x2000
        case kVK_RightShift: 0x04
        default: 0
        }
        return event.modifierFlags.rawValue & deviceMask != 0
    }

    /// Builds a shortcut from a key press. Returns nil for keys that would be
    /// unsafe as a global shortcut: anything without ⌘, ⌥ or ⌃ except F-keys.
    init?(event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }

        let isFunctionKey = Self.functionKeyCodes[keyCode] != nil
        guard isFunctionKey || modifiers & (cmdKey | optionKey | controlKey) != 0 else { return nil }

        let label = Self.functionKeyCodes[keyCode]
            ?? Self.namedKeyCodes[keyCode]
            ?? event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        guard let label, !label.isEmpty else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), keyLabel: label)
    }
}
