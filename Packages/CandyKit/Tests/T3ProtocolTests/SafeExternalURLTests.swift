import Foundation
import Testing
import T3Protocol

// `parseSafeExternalUrl`: links from web content and messages open only when they are http or https.
@Test func safeExternalURLAllowsOnlyWebSchemes() {
    #expect(SafeExternalURL.parse("https://example.com/a?b=1") != nil)
    #expect(SafeExternalURL.parse("HTTP://example.com") != nil)
    for unsafe in ["file:///Applications/Calculator.app", "javascript:alert(1)", "t3code://auth/codex", "vscode://file/etc/passwd",
                   "x-apple.systempreferences:com.apple.preference.security", "mailto:a@b.c", "smb://host/share", "not a url"] {
        #expect(SafeExternalURL.parse(unsafe) == nil, "\(unsafe)")
    }
}
