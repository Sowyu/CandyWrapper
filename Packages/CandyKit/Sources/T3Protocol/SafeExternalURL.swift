import Foundation

/// `parseSafeExternalUrl` (apps/desktop/src/electron/ElectronShell.ts:42-55): links from web content,
/// agent output and the server open in the system browser only when they are http or https.
/// T3 also lets remote-editor URLs through; CandyWrapper builds those itself in `OpenInEditors`.
public enum SafeExternalURL {
    public static func isSafe(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    public static func parse(_ string: String) -> URL? {
        URL(string: string).flatMap { isSafe($0) ? $0 : nil }
    }
}
