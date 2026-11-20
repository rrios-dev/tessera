import AppKit

/// Where the author is found, shown in the About panel: the website and its mailbox.
enum AboutCredits {
    static let website = URL(string: "https://rrios.dev")!
    static let email = "roberto@rrios.dev"
    static let mailto = URL(string: "mailto:roberto@rrios.dev")!

    /// The panel's credits: the website and the mailbox as links, centred.
    static func make() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString()
        for (label, url, last) in [("rrios.dev", website, false), (email, mailto, true)] {
            var attributes = base
            attributes[.link] = url
            credits.append(NSAttributedString(string: label, attributes: attributes))
            if !last { credits.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        return credits
    }
}
