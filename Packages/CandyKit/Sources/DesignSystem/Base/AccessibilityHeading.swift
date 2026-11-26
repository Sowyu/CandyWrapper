import AppKit

/// A heading for VoiceOver over a row other views draw, as T3 wraps an author line in `<h2>` or `<h3>`: the rotor
/// lists it under Headings and reads `label`. It draws nothing and takes no clicks; the host sets its frame over
/// the row and its label from the row's words.
public final class AccessibilityHeadingView: NSView {
    public var level: Int
    public var label = "" { didSet { setAccessibilityLabel(label) } }

    public init(level: Int) {
        self.level = level
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// WebKit reports a heading's level as its value.
    public override func accessibilityValue() -> Any? { level }
}
