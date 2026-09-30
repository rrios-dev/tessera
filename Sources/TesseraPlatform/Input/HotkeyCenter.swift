import Carbon
import Foundation
import TesseraPorts

/// Global hotkeys through Carbon: no CPU while idle and no event tap.
@MainActor
final class HotkeyCenter {
    private var references: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private let onPress: (Int) -> Void

    init(onPress: @escaping (Int) -> Void) {
        self.onPress = onPress
    }

    /// Registers every chord; returns, per chord, whether macOS accepted it. A press reports the
    /// chord's index.
    func register(_ chords: [KeyChord]) -> [Bool] {
        installHandlerIfNeeded()
        return chords.enumerated().map { index, chord in
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(chord.keyCode), Self.carbonModifiers(chord.flags),
                EventHotKeyID(signature: OSType(0x5453_5341), id: UInt32(index + 1)),
                GetApplicationEventTarget(), 0, &reference
            )
            guard status == noErr, let reference else { return false }
            references.append(reference)
            return true
        }
    }

    func unregisterAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
    }

    static func carbonModifiers(_ flags: KeyFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let center = Unmanaged<HotkeyCenter>.fromOpaque(refcon).takeUnretainedValue()
            let index = Int(hotKeyID.id) - 1
            MainActor.assumeIsolated { center.onPress(index) }
            return noErr
        }, 1, &spec, refcon, &eventHandler)
    }
}
