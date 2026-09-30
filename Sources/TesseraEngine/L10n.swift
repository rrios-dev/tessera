import Foundation

/// The product's words in Spanish and English, side by side so they never drift apart
/// (audit E10). Glossary (docs/glossary.md): **Escritorio / Desktop** is always a macOS desktop
/// (Mission Control); **Grupo / Group** is one of Tessera's emulated workspaces inside a desktop;
/// **Mosaico, Acordeón, Maximizado / Tiles, Accordion, Maximized** are the layouts.
public enum L10n {
    public enum Language: Sendable { case es, en }

    /// `TESSERA_LANGUAGE` wins; otherwise the user's first preferred language.
    public static let language: Language = {
        let explicit = ProcessInfo.processInfo.environment["TESSERA_LANGUAGE"]
        let preferred = explicit ?? Locale.preferredLanguages.first ?? "es"
        return preferred.hasPrefix("en") ? .en : .es
    }()

    public static func t(_ es: String, _ en: String) -> String {
        language == .es ? es : en
    }

    public static func layoutName(_ layout: String) -> String {
        switch layout {
        case "tiles": t("Mosaico", "Tiles")
        case "accordion": t("Acordeón", "Accordion")
        case "monocle": t("Maximizado", "Maximized")
        default: layout
        }
    }
}
