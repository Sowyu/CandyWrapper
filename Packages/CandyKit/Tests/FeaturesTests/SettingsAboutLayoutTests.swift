import AppKit
import Testing
import DesignSystem
@testable import Features

/// Round 3 item 5: About showed a third "Up to Date" button at the bottom left. The Legal slice's copy of General's
/// About section filters the Server runtime row out, and the row's binder unhid it once a runtime state arrived.
@MainActor
struct SettingsAboutLayoutTests {
    @Test func aboutDrawsOneButtonPerUpdateRow() {
        let context = SettingsPageContext()
        var app = DesktopUpdateState(currentVersion: "1.15.2", channel: .nightly, enabled: true)
        app.status = .upToDate
        var runtime = DesktopUpdateState(currentVersion: "0.1.12-nightly.20261120.5009", channel: .nightly, enabled: true)
        runtime.status = .upToDate
        context.update = app
        let page = ConcernSettingsView(context: context, section: .about)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        page.frame = NSRect(x: 0, y: 0, width: 720, height: page.height(forWidth: 720))
        window.contentView?.addSubview(page)
        page.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        // The runtime state arrives after the page first laid out, as it does in the app.
        context.runtimeUpdate = runtime
        page.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        var shown: [ButtonView] = []
        func walk(_ v: NSView) {
            if let b = v as? ButtonView, b.title == "Up to Date", !b.isHiddenOrHasHiddenAncestor { shown.append(b) }
            v.subviews.forEach(walk)
        }
        walk(page)
        #expect(shown.count == 2)
        for b in shown {
            let f = b.convert(b.bounds, to: page)
            #expect(f.minX > 360, "the button sits at the right of its row, got \(f)")
        }
    }
}
