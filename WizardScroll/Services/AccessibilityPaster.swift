import AppKit
import ApplicationServices
import Foundation

@MainActor
final class AccessibilityPaster {
    private let trustProvider: () -> Bool
    private let settingsOpener: (URL) -> Void

    init(
        trustProvider: @escaping () -> Bool = { AXIsProcessTrusted() },
        settingsOpener: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.trustProvider = trustProvider
        self.settingsOpener = settingsOpener
    }

    var isTrusted: Bool { trustProvider() }

    func openPermissionSettings() {
        guard !isTrusted else { return }

        // This is an explicit user action, not part of startup or a status
        // refresh. Only open the pane: also requesting the system prompt here
        // can queue another dialog while the user is already granting access.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            settingsOpener(url)
        }
    }

    @discardableResult
    func copyToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func insert(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw PasteError.clipboard }
        let insertedChangeCount = pasteboard.changeCount

        // Put the transcript on the clipboard before checking Accessibility. If
        // macOS blocks the synthetic Command-V event, the user's text is still
        // recoverable with a manual paste.
        guard isTrusted else {
            throw PasteError.accessibilityPermission
        }

        try await Task.sleep(for: .milliseconds(80))
        guard hasFocusedTextInput() else { throw PasteError.noInputTarget }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            throw PasteError.eventCreation
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        try? await Task.sleep(for: .milliseconds(700))
        if pasteboard.changeCount == insertedChangeCount {
            snapshot.restore(to: pasteboard)
        }
    }

    /// Chromium and Electron apps such as Slack and VS Code only build their
    /// accessibility tree once a client asks for it. Ask when recording starts,
    /// so the tree is ready by the time the transcript is pasted.
    func prepareForInsertion(into application: NSRunningApplication?) {
        guard isTrusted, let application else { return }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func hasFocusedTextInput() -> Bool {
        // Electron apps do not answer the system-wide focus query, so ask the
        // frontmost app directly and fall back to the system-wide element.
        let focusedValue = NSWorkspace.shared.frontmostApplication
            .flatMap { attribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication($0.processIdentifier)) }
            ?? attribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide())
        guard let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return false }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        let role = attribute(kAXRoleAttribute, of: focused) as? String
        let isEnabled = attribute(kAXEnabledAttribute, of: focused) as? Bool ?? true
        var valueIsSettable: DarwinBoolean = false
        var selectedTextIsSettable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &valueIsSettable)
        _ = AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &selectedTextIsSettable)
        let hasSettableText = selectedTextIsSettable.boolValue
            || (valueIsSettable.boolValue && attribute(kAXValueAttribute, of: focused) is String)

        return Self.supportsTextInput(role: role, isEnabled: isEnabled, hasSettableText: hasSettableText)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated static func supportsTextInput(role: String?, isEnabled: Bool, hasSettableText: Bool) -> Bool {
        guard isEnabled else { return false }
        // Terminal and some web editors expose text areas without settable AX
        // values, but still accept paste. Other custom editors must expose a
        // writable text attribute; desktop items, buttons and menus do not.
        return role == kAXTextFieldRole || role == kAXTextAreaRole || hasSettableText
    }
}

private struct PasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            snapshot.values.forEach { item.setData($0.1, forType: $0.0) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

enum PasteError: LocalizedError {
    case accessibilityPermission
    case noInputTarget
    case clipboard
    case eventCreation

    var errorDescription: String? {
        switch self {
        case .accessibilityPermission: "Enable Accessibility for WizardScroll, then try again"
        case .noInputTarget: "No focused text input is available for automatic paste"
        case .clipboard: "Unable to write the transcript to the clipboard"
        case .eventCreation: "Unable to create the paste keyboard event"
        }
    }
}
