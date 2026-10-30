import AppKit
import ApplicationServices
import Carbon

/// Sends Cmd+V to the frontmost app. Needs Accessibility permission.
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

/// A system-wide hotkey via Carbon. Works without any extra permission.
final class HotKey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                HotKey.action?()
                return noErr
            },
            1, &spec, nil, nil
        )

        let id = EventHotKeyID(signature: 0x434C_4950, id: 1) // 'CLIP'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
    }
}
