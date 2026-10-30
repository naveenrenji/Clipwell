import AppKit
import ApplicationServices

/// Finds the text caret of the focused app through the Accessibility API, so the history
/// opens next to where you are typing. Returns nil whenever the app does not expose it.
enum Caret {
    /// Caret rectangle in Cocoa screen coordinates (origin bottom-left).
    static func rect() -> NSRect? {
        guard Paster.isTrusted else { return nil }

        // Short timeouts: an unresponsive app must never stall the hotkey.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedRef = focused, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeRef = rangeValue, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }

        func bounds(of target: CFRange) -> CGRect? {
            var target = target
            guard let param = AXValueCreate(.cfRange, &target) else { return nil }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
                  let outRef = out, CFGetTypeID(outRef) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(outRef as! AXValue, .cgRect, &rect), rect != .zero else { return nil }
            return rect
        }

        var quartz: CGRect
        if let direct = bounds(of: range) {
            quartz = direct
        } else if range.location > 0, let previous = bounds(of: CFRange(location: range.location - 1, length: 1)) {
            // Some apps refuse a zero-length range; the character before the caret ends at the caret.
            quartz = CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        } else {
            return nil
        }

        // Accessibility uses a top-left origin on the primary display; Cocoa uses bottom-left.
        guard let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: quartz.minX, y: primary.frame.height - quartz.maxY, width: quartz.width, height: quartz.height)
    }
}
