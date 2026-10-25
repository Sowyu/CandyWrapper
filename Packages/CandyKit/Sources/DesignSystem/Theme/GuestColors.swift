import AppKit

/// T3's guest colors (apps/web/src/index.css:1138-1141, 1193 at 3669): messages from a guest link and the
/// sidebar's Request status. They come from the tokens extracted from 3669's stylesheet, so custom themes
/// mix `--guest-surface` with their own message surface.
public enum GuestColors {
    /// `--guest`: fuchsia-500 in both themes.
    public static var guest: NSColor { Themed.color(\.guest) }

    /// `--guest-foreground`: fuchsia-600, fuchsia-300 in dark.
    public static var foreground: NSColor { Themed.color(\.guestForeground) }

    /// `--guest-surface`: `color-mix(in srgb, var(--guest) 14%, var(--message-surface))`.
    public static var surface: NSColor { Themed.color(\.guestSurface) }
}
