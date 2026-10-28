import AppKit
import DesignSystem

/// The default themes follow Nightly 3814. Glass and Redesign retain their existing geometry.
enum ThreadDesign {
    static func uses3814(dark: Bool) -> Bool { !ThemeRuntime.framesPanes(dark: dark) }
    static var uses3814: Bool { uses3814(dark: NSAppearance.current.isDark) }

    static func layout(in appearance: NSAppearance, _ make: () -> MarkdownLayout) -> MarkdownLayout {
        var result: MarkdownLayout?
        appearance.performAsCurrentDrawingAppearance { result = make() }
        return result!
    }

    static let diffAddition = NSColor(name: nil) { appearance in
        Themed.color(uses3814(dark: appearance.isDark) ? \.diffAdditionForeground : \.diffAddition)
    }
    static let diffDeletion = NSColor(name: nil) { appearance in
        Themed.color(uses3814(dark: appearance.isDark) ? \.diffDeletionForeground : \.diffDeletion)
    }

    static let markdownBody = NSColor(name: nil) { appearance in
        Themed.color(\.foreground, uses3814(dark: appearance.isDark) ? 0.9 : 0.8)
    }
    static let inlineCodeFill = NSColor(name: nil) { appearance in
        uses3814(dark: appearance.isDark) ? Themed.color(\.contrastForeground, 0.1) : Themed.color(\.muted)
    }
    static let inlineCodeBorder = NSColor(name: nil) { appearance in
        uses3814(dark: appearance.isDark) ? .clear : Themed.color(\.contrastBorder)
    }
}

extension NSAttributedString.Key {
    static let markdownExternalLink = Self("CandyMarkdownExternalLink")
}
