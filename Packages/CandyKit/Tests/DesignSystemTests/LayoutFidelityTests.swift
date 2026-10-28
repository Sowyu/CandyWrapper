import AppKit
import Testing
@testable import DesignSystem

/// Layout batch fidelity against T3's markup in Chromium (specs from scripts/gen-layout-spec.py).
/// Reports: report-<component>.html under `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct LayoutFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "discovery-list": .init(0.045),
        "group": .init(0.08),
        "middle-truncate": .init(0.1),
        "number-field": .init(0.035, except: [
            "default.increment.focus-visible.dark": 0.09,
            "default.increment.focus-visible.light": 0.09,
            // A disabled field never takes keyboard focus; T3's capture forces the ring on anyway (measured 0.184).
            "disabled.focus-visible.dark": 0.28,
            "disabled.focus-visible.light": 0.28,
        ]),
        "panel-tab-close": .init(0.12, except: [
            "tab.focus-visible.dark": 0.18,
            "tab.focus-visible.light": 0.18,
        ]),
        "qr-code": .init(0.065),
        "scroll-area": .init(0.025),
        "settings": .init(0.035),
        "standalone-page": .init(0.045),
        "table": .init(0.045),
        "wizard-steps": .init(0.04),
    ]

    /// 32px rows with a bottom border, the ScrollArea test content.
    final class Rows: DSView {
        override var wantsUpdateLayer: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            Themed.color(\.contrastBorder).cgColor(in: self).asColor.setFill()
            for i in 0..<Int(bounds.height / 32) { NSRect(x: 0, y: CGFloat(i) * 32 + 31, width: bounds.width, height: 1).fill() }
        }
    }

    @Test func scrollArea() throws {
        try FormsFidelityTests.run("scroll-area", title: "ScrollArea", ceilings: Self.ceilings) { n, state, css in
            let rows = Rows(frame: NSRect(x: 0, y: 0, width: css.width, height: 384))
            let v = ScrollAreaView(documentView: rows, scrollFade: n["fade"] == "true")
            v.frame.size = css
            v.layoutSubtreeIfNeeded()
            v.scroll(to: NSPoint(x: 0, y: Double(n["offset"]!)!))
            v.previewScrollbar(visible: n["visible"] == "true", thumbHovered: state == "hover")
            return v
        }
    }

    @Test func settings() throws {
        try FormsFidelityTests.run("settings", title: "Settings", ceilings: Self.ceilings) { n, _, css in
            let all = [("Theme", "Choose how T3 Code looks on this device.", "System"),
                       ("Confirm thread deletion", "Ask before deleting a thread and its history.", "Enabled"),
                       ("Diff word wrap", nil, "Off")]
            let rows = all.prefix(Int(n["rows"]!)!).map { t, d, c in
                SettingsRowView(title: t, detail: d, control: ButtonView(c, variant: .outline, size: .sm))
            }
            let v = SettingsSectionView(title: n["title"]!, rows: Array(rows))
            v.frame.size = NSSize(width: css.width, height: v.height(forWidth: css.width))
            return v
        }
    }

    @Test func table() throws {
        try FormsFidelityTests.run("table", title: "Table", ceilings: Self.ceilings) { n, state, css in
            let v = DataTableView(headers: ["Process", "CPU", "Memory"],
                                  rows: [["t3 serve", "0.4%", "182 MB"], ["claude", "2.1%", "96 MB"], ["git status", "0.0%", "4 MB"]])
            if let s = n["selected"] { v.selectedRows = [Int(s)!] }
            if state == "hover" { v.hoveredRow = 1 }
            v.frame.size.width = css.width
            return v
        }
    }

    @Test func group() throws {
        try FormsFidelityTests.run("group", title: "Group", ceilings: Self.ceilings) { n, state, _ in
            let variant = ButtonView.Variant(rawValue: n["variant"]!)!
            let buttons = n["titles"]!.split(separator: ",").map { ButtonView(String($0), variant: variant, size: .sm) }
            let target = variant == .outline ? buttons[1] : buttons[0]
            target.previewState(FidelityTests.controlState(state))
            return GroupView(buttons: buttons, separators: n["separators"] == "true")
        }
    }

    @Test func standalonePage() throws {
        try FormsFidelityTests.run("standalone-page", title: "StandalonePage", ceilings: Self.ceilings) { n, _, css in
            let v = StandalonePageView(tone: StandalonePageView.Tone(rawValue: n["tone"]!)!, eyebrow: n["eyebrow"]!, title: n["title"]!, text: n["text"]!)
            v.frame.size = css
            return v
        }
    }

    @Test func wizardSteps() throws {
        try FormsFidelityTests.run("wizard-steps", title: "WizardSteps", ceilings: Self.ceilings) { n, state, css in
            let v = WizardStepsView(steps: n["steps"]!.split(separator: ",").map(String.init), currentStep: Int(n["current"]!)!)
            v.stepViews[2].previewState(FidelityTests.controlState(state))
            v.frame.size.width = css.width
            return v
        }
    }

    @Test func discoveryList() throws {
        try FormsFidelityTests.run("discovery-list", title: "DiscoveryList", ceilings: Self.ceilings) { _, state, css in
            let rows = [DiscoveryRowView(icon: .folder, title: "candywrapper", detail: "~/Projects/candywrapper"),
                        DiscoveryRowView(icon: .terminal, title: "t3code", detail: "~/Projects/t3code, a very long description that truncates")]
            rows[0].previewState(FidelityTests.controlState(state))
            let v = DiscoveryListView(rows: rows)
            v.frame.size.width = css.width
            return v
        }
    }

    @Test func middleTruncate() throws {
        try FormsFidelityTests.run("middle-truncate", title: "MiddleTruncate", ceilings: Self.ceilings) { n, _, css in
            // The reference box is the flex item's width; our intrinsic width is the untruncated text.
            let box = DSView(frame: NSRect(origin: .zero, size: css))
            let v = MiddleTruncateView(n["value"]!)
            v.frame = NSRect(x: 0, y: 0, width: min(css.width, v.intrinsicContentSize.width), height: css.height)
            box.addSubview(v)
            return box
        }
    }

    /// `splitForMiddleTruncate` cases.
    @Test func middleTruncateSplit() {
        #expect(MiddleTruncateView.split("/Users/mrm/Sources/ScrollAreaView.swift")?.tail == "swift") // segment over 16: 10
        #expect(MiddleTruncateView.split("/Users/mrm/Sources/Short.swift")?.tail == "Short.swift")
        #expect(MiddleTruncateView.split("fix/cache-main-20260918-180825")?.tail == "180825")
        #expect(MiddleTruncateView.split("main") == nil)
        #expect(MiddleTruncateView.split("fix/cache-main-20260918-180825", classic: true)?.tail == "918-180825")
        #expect(MiddleTruncateView.split("abcdefghijklmn") == nil)  // 14 chars: tail 10 + 4
        #expect(MiddleTruncateView.split("abcdefghijklmno")?.head == "abcde")
        #expect(MiddleTruncateView.split("abcdef", tail: 1)?.tail == "f")
    }

    @Test func panelTabClose() throws {
        try FormsFidelityTests.run("panel-tab-close", title: "PanelTabCloseButton", ceilings: Self.ceilings) { n, state, _ in
            let icon = IconView(name: .terminal, size: 12, strokeColor: Themed.color(\.contrastMutedForeground))
            let b = PanelTabCloseButton(identity: icon)
            let buttonTarget = n["buttonTarget"] == "true"
            // The tab row is the hover target in case "tab"; the button itself in "button-hover".
            b.isTabHovered = state == "hover"
            if buttonTarget { b.previewState(FidelityTests.controlState(state)) }
            else if state == "focus-visible" { b.isTabHovered = false }
            let row = DSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
            row.addSubview(b)
            b.frame = NSRect(x: 4, y: 4, width: 16, height: 16)
            return row
        }
    }

    @Test func qrCode() throws {
        try FormsFidelityTests.run("qr-code", title: "QRCode", ceilings: Self.ceilings) { n, _, _ in
            let level: QRCode.Ecc = ["L": .low, "M": .medium, "Q": .quartile, "H": .high][n["level"]!]!
            return QRCodeView(value: n["value"]!, size: CGFloat(Double(n["size"]!)!), level: level, marginSize: Int(n["margin"]!)!)
        }
    }

    @Test func numberField() throws {
        try FormsFidelityTests.run("number-field", title: "NumberField", ceilings: Self.ceilings) { n, state, css in
            let v = NumberFieldView(value: Double(n["value"]!)!, size: NumberFieldView.Size(rawValue: n["size"]!)!)
            if n["disabled"] == "true" { v.isEnabled = false }
            else {
                if state == "focus-visible" { v.previewFocus(true) }
                if state == "hover", n["target"] == "increment" { v.increment.previewState(FidelityTests.controlState("hover")) }
                if state == "focus-visible", n["target"] == "increment" { v.previewFocus(true) }
            }
            v.frame.size.width = css.width
            return v
        }
    }
}

private extension CGColor {
    var asColor: NSColor { NSColor(cgColor: self) ?? .clear }
}
