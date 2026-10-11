import AppKit
import DesignSystem

/// SettingsFontPreviews.tsx:25-77. Use the real editor and diff renderer so the sample follows their metrics.
final class SettingsFontPreviewView: DSView, SettingsGroupRow {
    enum Kind { case prompt, code, terminal }
    private let kind: Kind
    private var surface: NSView?
    init(_ kind: Kind) { self.kind = kind; super.init(frame: .zero) }
    func height(forWidth width: CGFloat) -> CGFloat { kind == .prompt ? 100 : 132 }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { surface?.removeFromSuperview(); surface = nil; return }
        guard surface == nil else { return }
        switch kind {
        case .prompt:
            let editor = ComposerEditor()
            editor.setText("Use $frontend-design to fix the flaky test in [surface.test.ts](apps/web/src/terminal/ghostty/surface.test.ts) and align the header with [SettingsPanels.tsx](apps/web/src/components/settings/SettingsPanels.tsx) before shipping.")
            surface = editor
        case .code:
            let diff = DiffListView()
            diff.setDiff(UnifiedDiff("diff --git a/src/formatUser.ts b/src/formatUser.ts\n--- a/src/formatUser.ts\n+++ b/src/formatUser.ts\n@@ -1,3 +1,3 @@\n export function formatUser(user: User) {\n-  return user.name.toUpperCase();\n+  return `${user.name} <${user.email}>`; // 0O 1lI\n }\n"), collapsedByDefault: false)
            surface = diff
        case .terminal:
            let terminal = TerminalSurfaceView()
            terminal.apply(.write("\u{1B}[?25l$ git status\r\nOn branch main\r\n\u{1B}[32mAll checks passed\u{1B}[0m\r\n0O 1lI  { } [ ] ( )"))
            surface = terminal
        }
        if let surface { addSubview(surface) }
        needsLayout = true
    }
    override func layout() { super.layout(); surface?.frame = bounds.insetBy(dx: 12, dy: 8) }
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        layer?.borderWidth = 1; layer?.cornerRadius = 8
    }
}
