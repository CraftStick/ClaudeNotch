import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's RegisterEventHotKey: unlike a global key monitor it
/// needs no Accessibility permission. Registered only while they are needed.
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// `keyCode` is a kVK_ constant, `modifiers` Carbon flags such as `cmdKey`.
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: OSType(0x434E_4F54), id: id),  // "CNOT"
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }  // taken by another app
        refs.append(ref)
        actions[id] = action
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }
}

/// The modifiers that go with Y, N and 1…4 to answer from the notch: ⌃⌥⌘ unless changed in the
/// settings, or none at all to keep every key for other apps.
enum HotKeyChoice: String, CaseIterable {
    case controlOptionCommand, controlOption, optionCommand, controlCommand, off

    static let key = "hotKeys"

    static var current: HotKeyChoice {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .controlOptionCommand
    }

    /// Carbon flags; nil when switched off.
    var modifiers: Int? {
        switch self {
        case .controlOptionCommand: return controlKey | optionKey | cmdKey
        case .controlOption: return controlKey | optionKey
        case .optionCommand: return optionKey | cmdKey
        case .controlCommand: return controlKey | cmdKey
        case .off: return nil
        }
    }

    var symbols: String {
        switch self {
        case .controlOptionCommand: return "⌃⌥⌘"
        case .controlOption: return "⌃⌥"
        case .optionCommand: return "⌥⌘"
        case .controlCommand: return "⌃⌘"
        case .off: return ""
        }
    }

    /// What a button shows for `key`, as "⌃⌥⌘Y"; nothing when they're off.
    func label(_ key: String) -> String { self == .off ? "" : symbols + key }
}
