import AppKit
import DesignSystem
import T3Store

/// Glass Native's floating working pill (T3 Mobile floating-working-control.tsx:58-64, 174): a 44 pt Liquid Glass
/// capsule above the composer while a turn works, the thread syncs or compacts, or the environment reconnects.
/// The elapsed time ticks on the shared `LabelClock`, once a second and only while the pill can be seen. Hidden, it
/// holds no glass, no label and no tick.
public final class NativeWorkingPillView: NSView {
    public enum State: Equatable, Sendable {
        case working(sinceMs: Int64?)
        case compacting, syncing, reconnecting
    }

    public static let height: CGFloat = 44
    private static let padX: CGFloat = 16, icon: CGFloat = 16, gap: CGFloat = 8

    public var state: State? { didSet { if state != oldValue { update() } } }
    /// Wall-clock milliseconds; tests replace it.
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    private var content: (glass: NSView, symbol: NSImageView, label: NSTextField)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityRole(.staticText)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// The capsule's width for its text.
    public var fittingWidth: CGFloat {
        guard let label = content?.label else { return 0 }
        return ceil(Self.padX * 2 + Self.icon + Self.gap + label.intrinsicContentSize.width)
    }

    /// Whether a tick is pending, for tests.
    var holdsTick: Bool { LabelClock.shared.due(for: self) != nil }
    var holdsContent: Bool { content != nil }

    private func update() {
        guard let state else {
            LabelClock.shared.cancel(self)
            content?.glass.removeFromSuperview()
            content = nil
            isHidden = true
            return
        }
        let parts = content ?? makeContent()
        content = parts
        isHidden = false
        parts.symbol.image = NSImage(systemSymbolName: Self.symbol(state), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        tick()
        superview?.needsLayout = true
    }

    private static func symbol(_ state: State) -> String {
        switch state {
        case .working: "sparkles"
        case .compacting: "arrow.down.right.and.arrow.up.left"
        case .syncing: "arrow.triangle.2.circlepath"
        case .reconnecting: "wifi.exclamationmark"
        }
    }

    /// The text, and the next tick while the elapsed time shows.
    private func tick() {
        guard let state, let label = content?.label else { return }
        let text: String
        switch state {
        case .working(let since?):
            let elapsed = max(0, nowMs() - since)
            let seconds = elapsed / 1000
            text = "Working for " + (seconds < 60 ? "\(seconds)s" : formatDuration(Double(seconds) * 1000))
            LabelClock.shared.schedule(self, in: Double(1000 - elapsed % 1000) / 1000) { [weak self] in self?.tick() }
        case .working(nil):
            text = "Working…"
            LabelClock.shared.cancel(self)
        case .compacting:
            text = "Compacting…"
            LabelClock.shared.cancel(self)
        case .syncing:
            text = "Syncing…"
            LabelClock.shared.cancel(self)
        case .reconnecting:
            text = "Reconnecting…"
            LabelClock.shared.cancel(self)
        }
        if label.stringValue != text {
            label.stringValue = text
            setAccessibilityLabel(text)
            superview?.needsLayout = true
        }
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); LabelClock.shared.visibilityChanged() }
    public override func viewDidUnhide() { super.viewDidUnhide(); LabelClock.shared.visibilityChanged() }

    private func makeContent() -> (glass: NSView, symbol: NSImageView, label: NSTextField) {
        let symbol = NSImageView()
        symbol.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 13 * FontRuntime.interfaceScale, weight: .medium)
        label.textColor = .labelColor
        let glass: NSView
        let host: NSView
        if #available(macOS 26, *) {
            let effect = NSGlassEffectView()
            effect.cornerRadius = Self.height / 2
            let inner = NSView()
            effect.contentView = inner
            glass = effect
            host = inner
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.state = .followsWindowActiveState
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.height / 2
            effect.layer?.masksToBounds = true
            glass = effect
            host = effect
        }
        host.addSubview(symbol)
        host.addSubview(label)
        addSubview(glass)
        return (glass, symbol, label)
    }

    public override func layout() {
        super.layout()
        guard let content else { return }
        content.glass.frame = bounds
        let labelSize = content.label.intrinsicContentSize
        content.symbol.frame = NSRect(x: Self.padX, y: (bounds.height - Self.icon) / 2, width: Self.icon, height: Self.icon)
        // The glass's content view isn't flipped; center vertically either way.
        content.label.frame = NSRect(x: Self.padX + Self.icon + Self.gap, y: ((bounds.height - labelSize.height) / 2).rounded(),
                                     width: labelSize.width, height: labelSize.height)
    }
}
