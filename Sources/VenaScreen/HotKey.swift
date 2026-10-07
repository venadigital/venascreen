import Carbon

/// Global shortcuts through the Carbon hot key API. Unlike a global key
/// monitor, they need no Accessibility permission.
///
/// Registration fails when another app already owns the same combination,
/// for example another screenshot tool. `isRegistered` tells the menu about it.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    let isRegistered: Bool

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.installHandlerIfNeeded()
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x5645_4E41), id: id) // "VENA"
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &newRef)
        ref = newRef
        isRegistered = status == noErr && newRef != nil
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }

    /// One handler for every shortcut, dispatching on the hot key id.
    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
