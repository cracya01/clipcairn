import AppKit
import Carbon

/// Global hotkeys through the Carbon event API (no extra permission needed).
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()
    var handler: ((HotAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func register(_ shortcuts: [HotAction: Shortcut]) {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        installIfNeeded()
        for (i, action) in HotAction.allCases.enumerated() {
            guard let s = shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x434C_4950), id: UInt32(i))  // 'CLIP'
            let st = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else {
                NSLog("Clipcairn: hotkey \(s.display) for \(action.rawValue) not registered (\(st))")
            }
        }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let i = Int(hk.id)
            MainActor.assumeIsolated {
                guard i < HotAction.allCases.count else { return }
                Hotkeys.shared.handler?(HotAction.allCases[i])
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
