// Screens built from DesignSystem components, fed by T3Store.

import WebKit

/// View > Force Reload. T3 calls `webContents.reloadIgnoringCache()` on the main window (DesktopWindow.ts:1048),
/// which throws away everything the renderer held: loaded images and their measured sizes, favicons, failed-host
/// lists, avatars, and the iframes' web storage. This drops the native copies of the same things.
@MainActor
public enum ForceReloadCaches {
    public static func clear() {
        MarkdownImages.clear()
        MarkdownFavicons.clear()
        MarkdownContextChips.thumbnails = [:]
        MarkdownContextChips.failed = []
        PullRequestAvatarView.cache = [:]
        ThreadWebFrameBudget.clearData()
    }
}
