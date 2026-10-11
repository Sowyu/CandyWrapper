import AppKit
import DesignSystem

/// ComposerCodeBlockLanguagePicker.tsx:39-137. Search matches both the label and language id.
final class ComposerCodeLanguagePickerView: DSView, PickerPopupBody {
    let search = InputView(placeholder: "Search languages", size: .sm)
    private let scroll = NSScrollView()
    private var choicesView: PickerMenuView?
    private let info: String
    var onPick: ((String) -> Void)?
    init(info: String) {
        self.info = info
        super.init(frame: .zero)
        search.unstyled = true
        search.setAccessibilityLabel("Search languages")
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        addSubview(search); addSubview(scroll)
        search.onChange = { [weak self] _ in self?.reload() }
        reload()
    }
    var naturalSize: CGSize { CGSize(width: 222, height: 35 + min(280, choicesView?.naturalSize.height ?? 36)) }
    private func reload() {
        let choices = ComposerCodeLanguages.filtered(search.text, current: info)
        let entries: [PickerMenuEntry] = choices.isEmpty ? [.label("No matching languages.")] : choices.map { entry in
            .option(entry.label, checked: ComposerCodeLanguages.label(info) == entry.label) { [weak self] in self?.onPick?(entry.id) }
        }
        let list = PickerMenuView(entries: entries, style: .select, minimumWidth: 222)
        list.highlightedIndex = choices.isEmpty ? nil : 0
        choicesView = list; scroll.documentView = list
        needsLayout = true
        if let host = popupHost, let popup = host.popups.last { host.reposition(popup) }
    }
    override func updateLayer() { layer?.backgroundColor = Themed.color(\.popover).cgColor(in: self) }
    override func layout() {
        super.layout()
        search.frame = NSRect(x: 8, y: 4, width: bounds.width - 16, height: 28)
        scroll.frame = NSRect(x: 0, y: 35, width: bounds.width, height: bounds.height - 35)
        choicesView?.frame = NSRect(origin: .zero, size: CGSize(width: bounds.width, height: choicesView?.naturalSize.height ?? 0))
    }
    func handleKey(_ key: PopupKey) -> Bool {
        // Space belongs to the search query, not the highlighted choice.
        if key == .space { return false }
        let handled = choicesView?.handleKey(key) ?? false
        if let index = choicesView?.highlightedIndex { choicesView?.scrollToVisible(NSRect(x: 0, y: 4 + CGFloat(index) * 28, width: 222, height: 28)) }
        return handled
    }
}
