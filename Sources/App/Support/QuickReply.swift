import AppKit
import ApplicationServices

/// A short reply to a session that's done, from a button in the notch: brings the session forward the
/// way a click on the notch does, then types the reply and Return, as you would.
///
/// Typing for you needs Accessibility access, asked for the first time. It types nothing unless it's sure
/// where the keys go: in Terminal and iTerm the session's very tab must have come forward; in the Claude app
/// that session must have opened, with the cursor in a text field or nothing in focus. Elsewhere (an editor's terminal, say)
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
        guard supports(s) else { return false }
        guard AXIsProcessTrustedWithOptions(ask) else {
            EventLog.append("Quick reply: no Accessibility access yet, macOS asked for it")
            return false
        }
        EventLog.append("Quick reply")
        let start = Date()
        if inClaudeApp(s) {
            // Asked now, Electron has its text fields ready to tell about by the time it's looked.
            NSRunningApplication.runningApplications(withBundleIdentifier: AppFocus.claudeBundleID).forEach {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication($0.processIdentifier), "AXManualAccessibility" as CFString,
                                             kCFBooleanTrue)
            }
            // Only once that very session was opened, and has had a moment to come up: until then the
            // cursor may be in another one's field.
            AppFocus.openInClaudeApp(s.id, opened: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    whenReady(AppFocus.claudeBundleID, needsTextField: true, since: start) { type(text) }
                }
            }, otherwise: { AppFocus.show(host: s.host, folder: s.cwd, tty: s.tty) })
        } else if let host = s.host {
            AppFocus.show(host: host, folder: s.cwd, tty: s.tty) { found in
                if found { whenReady(host, needsTextField: false, since: start) { type(text) } }
            }
        }
        return true
    }

    /// Runs `then` once `host` is in front (and, if asked, has the cursor in a text field), checking
    /// every 0.1 s for up to 3 s; never if it doesn't get there.
    private static func whenReady(_ host: String, needsTextField: Bool, since start: Date, tries: Int = 30,
                                  then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let app = NSWorkspace.shared.frontmostApplication
            let role = needsTextField && app?.bundleIdentifier == host ? focusedRole(app!.processIdentifier) : ""
            // The Claude app often tells of nothing in focus even with the cursor in its field: keys typed with
            // nothing in focus go nowhere, so only something else in focus (a button Return would press) stops it.
            if app?.bundleIdentifier == host, !needsTextField || role.isEmpty || textRoles.contains(role) {
                // A moment more: a window that just came forward may still be taking the keyboard.
                EventLog.append("Quick reply: typed into \(host)\(role.isEmpty ? "" : " (\(role))") after "
                                + String(format: "%.1f s", Date().timeIntervalSince(start) + 0.1))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: then)
            } else if tries > 0 {
                whenReady(host, needsTextField: needsTextField, since: start, tries: tries - 1, then: then)
            } else {
                EventLog.append(app?.bundleIdentifier == host
                    ? "Quick reply: not typed, the cursor isn't in a text field (\(role.isEmpty ? "nothing focused" : role))"
                    : "Quick reply: not typed, \(host) didn't come forward (\(app?.bundleIdentifier ?? "nothing") is)")
            }
        }
    }

    private static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]

    /// The role of what has the keyboard in the app, "" when it can't be told. An Electron app like
    /// Claude's only tells once asked to, with AXManualAccessibility.
    private static func focusedRole(_ pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return "" }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        return role as? String ?? ""
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
