import AppKit
import DesignSystem

/// The default themes follow Nightly 3814. Glass and Redesign retain their existing geometry.
enum ThreadDesign {
    /// A scoped layout choice lets callers render either design without changing the app's theme.
    @TaskLocal static var layoutUses3814: Bool?
    static func uses3814(dark: Bool) -> Bool { layoutUses3814 ?? !ThemeRuntime.framesPanes(dark: dark) }
    static var uses3814: Bool { uses3814(dark: NSAppearance.current.isDark) }

    static func layout(in appearance: NSAppearance, design: Bool? = layoutUses3814, _ make: () -> MarkdownLayout) -> MarkdownLayout {
        var result: MarkdownLayout?
        $layoutUses3814.withValue(design) {
            appearance.performAsCurrentDrawingAppearance { result = make() }
        }
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
    static let markdownMath = NSAttributedString.Key("CandyMarkdownMath")
    static let markdownExternalLink = Self("CandyMarkdownExternalLink")
}
