import Foundation
import TesseraConfig
import TesseraCore
import TesseraPorts

extension Engine {
    /// Registers the keymap for the current state: everything while active, only the pause
    /// chord while paused, nothing without permission or in safe mode (audit E4, E5).
    func registerKeymap() {
        guard options.hotkeys else { return }
        let voiceOver = port.voiceOverEnabled()
        let (bindings, errors) = Keymap.applying(localConfig.keys, to: Keymap.defaults(voiceOver: voiceOver))
        keymap = bindings
        for error in errors where warnedOnce.insert("key-\(error)").inserted {
            notify(Notice("config-keys", .warning, L10n.t("Atajo no aplicado: \(error)", "Shortcut not applied: \(error)")))
        }
        let wanted: [KeyBinding]
        switch status {
        case .active: wanted = bindings
        case .paused: wanted = bindings.filter { $0.action == .togglePause }
        default: wanted = []
        }
        guard wanted != registered else { return }
        port.unregisterHotkeys()
        registered = []
        guard !wanted.isEmpty else { return }
        let accepted = port.registerHotkeys(wanted.map(\.chord))
        registered = wanted
        let refused = zip(wanted, accepted).filter { !$0.1 }.map(\.0)
        if !refused.isEmpty, warnedOnce.insert("refused-\(refused.map(\.name).joined())").inserted {
            notify(Notice("hotkeys-refused", .warning, L10n.t(
                "macOS no aceptó \(refused.count) atajos (\(refused.prefix(3).map(\.chord.glyphs).joined(separator: ", "))): otra app los usa.",
                "macOS refused \(refused.count) shortcuts (\(refused.prefix(3).map(\.chord.glyphs).joined(separator: ", "))): another app uses them."
            )))
        }
        let clashes = Keymap.clashes(wanted, with: port.symbolicHotkeys())
        if !clashes.isEmpty, warnedOnce.insert("clash-\(clashes.map(\.binding.name).joined())").inserted {
            notify(Notice("hotkeys-clash", .warning, L10n.t(
                "\(clashes.count) atajos de Tessera coinciden con atajos de macOS (\(clashes.prefix(3).map(\.binding.chord.glyphs).joined(separator: ", "))). Cámbialos en la configuración.",
                "\(clashes.count) Tessera shortcuts match macOS shortcuts (\(clashes.prefix(3).map(\.binding.chord.glyphs).joined(separator: ", "))). Change them in the configuration."
            ), onScreen: false))
        }
        publishUI()
    }

    func pressHotkey(_ index: Int) {
        guard registered.indices.contains(index) else { return }
        hideCheatsheet()
        switch registered[index].action {
        case .togglePause: togglePause()
        case .command(let command): execute(command)
        }
    }

    /// VoiceOver uses Control+Option: with it on, every chord gains Command, live (audit E5).
    func voiceOverChanged(_ enabled: Bool) {
        registerKeymap()
        let glyphs = Keymap.modifiers(voiceOver: enabled).isSuperset(of: [.command]) ? "⌃⌥⌘" : "⌃⌥"
        notify(Notice("keymap-voiceover", .info, enabled
            ? L10n.t("VoiceOver activo: los atajos de Tessera pasan a \(glyphs).", "VoiceOver is on: Tessera's shortcuts move to \(glyphs).")
            : L10n.t("VoiceOver desactivado: los atajos de Tessera vuelven a \(glyphs).", "VoiceOver is off: Tessera's shortcuts go back to \(glyphs).")))
    }

    /// Holding exactly the base modifiers for a moment shows the shortcut overlay.
    func modifiersChanged(_ flags: KeyFlags) {
        modifiersHeld = flags
        let base = Keymap.modifiers(voiceOver: port.voiceOverEnabled())
        guard status.isActive, flags == base else {
            hideCheatsheet()
            return
        }
        cheatsheetToken += 1
        let token = cheatsheetToken
        after(timing.cheatsheetHold) { [weak self] in
            guard let self, self.cheatsheetToken == token, self.modifiersHeld == base, !self.cheatsheetVisible else { return }
            self.cheatsheetVisible = true
            self.ui.showCheatsheet(true)
        }
    }

    func hideCheatsheet() {
        cheatsheetToken += 1
        guard cheatsheetVisible else { return }
        cheatsheetVisible = false
        ui.showCheatsheet(false)
    }
}
