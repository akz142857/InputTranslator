import Carbon

@MainActor
final class HotkeyManager {
    private let signature: OSType
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var currentHotkey: Hotkey?
    private var currentID: UInt32 = 0
    private let action: @MainActor () -> Void

    init(signature: OSType = 0x4954524E, action: @escaping @MainActor () -> Void) {
        self.signature = signature
        self.action = action
    }

    func register(_ hotkey: Hotkey) -> Bool {
        if currentHotkey == hotkey { return true }

        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
                guard let event, let data else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                let id = identifier.id
                let signature = identifier.signature
                let manager = Unmanaged<HotkeyManager>.fromOpaque(data).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard signature == manager.signature, id == manager.currentID else {
                        return OSStatus(eventNotHandledErr)
                    }
                    manager.action()
                    return noErr
                }
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return false }
        }

        // Keep the previous shortcut active if registration of the new one fails.
        var newRegistration: EventHotKeyRef?
        let nextID = currentID &+ 1
        let identifier = EventHotKeyID(signature: signature, id: nextID)
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, identifier, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &newRegistration
        )
        guard status == noErr, let newRegistration else { return false }
        if let registration { UnregisterEventHotKey(registration) }
        registration = newRegistration
        currentID = nextID
        currentHotkey = hotkey
        return true
    }

    func stop() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
        currentHotkey = nil
    }
}
