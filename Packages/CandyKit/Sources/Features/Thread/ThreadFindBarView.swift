import AppKit
import DesignSystem
import T3Protocol

/// ThreadFindBar.tsx:27-122. The owner cancels requests when this view closes.
public final class ThreadFindBarView: DSView {
    public let group = InputGroupView(placeholder: "Find in thread", variant: .popover, size: .lg)
    public var input: InputView { group.input }
    private let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let previous = ButtonView(icon: .chevronUp, variant: .ghost, size: .iconXs)
    private let next = ButtonView(icon: .chevronDown, variant: .ghost, size: .iconXs)
    private let close = ButtonView(icon: .x, variant: .ghost, size: .iconXs)
    private let retry = ButtonView("Retry", variant: .ghost, size: .xs)
    public var onStep: ((Int) -> Void)?
    public var onClose: (() -> Void)?
    public var onRetry: (() -> Void)?
    public override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(group)
        [count, previous, next, close, retry].forEach(addSubview)
        previous.setAccessibilityLabel("Previous match")
        next.setAccessibilityLabel("Next match")
        close.setAccessibilityLabel("Close find")
        input.setAccessibilityLabel("Find in thread")
        previous.action = { [weak self] in self?.onStep?(-1) }
        next.action = { [weak self] in self?.onStep?(1) }
        close.action = { [weak self] in self?.onClose?() }
        retry.action = { [weak self] in self?.onRetry?() }
        input.onSubmit = { [weak self] in self?.onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1) }
        input.onCommand = { [weak self] command in
            guard command == #selector(NSResponder.cancelOperation(_:)) else { return false }
            self?.onClose?(); return true
        }
        present(query: "", index: 0, total: 0)
    }
    public func present(query: String, index: Int, total: Int, loading: Bool = false, failed: Bool = false) {
        count.text = failed ? "Search failed" : loading ? "Searching…" : query.isEmpty ? "" : total == 0 ? "0/0" : "\(index + 1)/\(total)"
        count.color = !query.isEmpty && total == 0 && !loading && !failed ? Themed.color(\.destructive) : Themed.color(\.mutedForeground)
        previous.isEnabled = total > 0 && !loading && !failed
        next.isEnabled = previous.isEnabled
        retry.isHidden = !failed
        needsLayout = true
    }
    public func focus() {
        window?.makeFirstResponder(input)
        (window?.firstResponder as? NSTextView)?.selectAll(nil)
    }
    public override func layout() {
        super.layout()
        group.frame = bounds
        group.layoutSubtreeIfNeeded()
        var x = bounds.width - 6
        for button in [close, next, previous] {
            x -= 24; button.frame = NSRect(x: x, y: 6, width: 24, height: 24)
        }
        if !retry.isHidden { x -= 42; retry.frame = NSRect(x: x, y: 6, width: 42, height: 24) }
        let w = max(40, ceil(count.textWidth))
        x -= w + 4
        count.frame = NSRect(x: x, y: 10, width: w, height: 16)
        input.frame.size.width = max(0, x - 2)
    }
}

/// Server results identify entries, not native views (orchestrationV2.ts:3505-3551).
public struct ThreadFindResult: Decodable, Equatable, Sendable {
    public struct Match: Decodable, Equatable, Sendable {
        public var entryId: String
        public var runId: String?
        public var occurrence: Int
    }
    public var totalMatches: Int
    public var activeIndex: Int
    public var match: Match?
    public static func step(_ index: Int, count: Int, delta: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}

/// index.css:2076-2084. Shared by messages and the composer.
public enum ThreadChatWidth {
    public static func maximum(_ setting: String) -> CGFloat {
        switch setting { case "wide": 1152; case "full": .greatestFiniteMagnitude; default: 736 }
    }
}
