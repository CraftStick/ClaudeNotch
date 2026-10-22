import AppKit
import ApplicationServices

/// A short reply to a session that's done, from a button in the notch: brings the session forward the
/// way a click on the notch does, then types the reply and Return, as you would.
///
/// Typing for you needs Accessibility access, asked for the first time. It types nothing unless it's sure
/// where the keys go: in Terminal and iTerm the session's very tab must have come forward; in the Claude app
/// that session must have opened and the cursor be in a text field. Elsewhere (an editor's terminal, say)
/// the keys could land in your code, so there are no buttons there.
enum QuickReply {
    /// The session runs where a reply can be typed safely.
    static func supports(_ s: Session) -> Bool {
        inClaudeApp(s) || AppFocus.canShowTab(host: s.host, tty: s.tty)
    }

    private static func inClaudeApp(_ s: Session) -> Bool {
        s.host == AppFocus.claudeBundleID || s.entrypoint == "claude-desktop"
    }

    /// False when Accessibility access isn't there yet: macOS has just been asked to show its dialog.
    @discardableResult
    static func send(_ text: String, to s: Session) -> Bool {
        let ask = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard supports(s), AXIsProcessTrustedWithOptions(ask) else { return false }
        EventLog.append("Quick reply")
        if inClaudeApp(s) {
            // Only once that very session was opened, and has had a moment to come up: until then the
            // cursor may be in another one's field.
            AppFocus.openInClaudeApp(s.id, opened: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    whenReady(AppFocus.claudeBundleID, needsTextField: true) { type(text) }
                }
            }, otherwise: { AppFocus.show(host: s.host, folder: s.cwd, tty: s.tty) })
        } else if let host = s.host {
            AppFocus.show(host: host, folder: s.cwd, tty: s.tty) { found in
                if found { whenReady(host, needsTextField: false) { type(text) } }
            }
        }
        return true
    }

    /// Runs `then` once `host` is in front (and, if asked, has the cursor in a text field), checking
    /// every 0.1 s for up to 3 s; never if it doesn't get there.
    private static func whenReady(_ host: String, needsTextField: Bool, tries: Int = 30, then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == host,
               !needsTextField || hasTextFieldFocused(app.processIdentifier) {
                // A moment more: a tab that just came forward may still be taking the keyboard.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: then)
            } else if tries > 0 {
                whenReady(host, needsTextField: needsTextField, tries: tries - 1, then: then)
            } else {
                EventLog.append("Quick reply: not typed, \(host) didn't come forward")
            }
        }
    }

    private static func hasTextFieldFocused(_ pid: pid_t) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let element = focused else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        return [kAXTextAreaRole, kAXTextFieldRole].contains(role as? String ?? "")
    }

    /// The text as typed characters, a few at a time, then Return.
    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            let chunk = Array(units[start..<min(start + 16, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
        }
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)  // Return
        }
    }
}
