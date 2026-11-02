import Carbon.HIToolbox
import Foundation

/// Global ⌃⌥ hotkeys via Carbon (no Accessibility permission needed).
enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []
    private static var installed = false

    static func register(_ keyCode: Int, _ action: @escaping () -> Void) {
        if !installed { install() }
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4C41_4742), id: id) // 'LAGB'
        RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), hkID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    private static func install() {
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
