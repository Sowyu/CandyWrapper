import AppKit
import DesignSystem
import T3Protocol

/// Named sets of list preferences kept on this device (4928 apps/web/src/components/SavedViewsMenu.tsx,
/// packages/client-runtime/src/savedViews.ts), shared by the Pull Requests and Issues pages
/// (#29387, #37963). A view's preferences are the page's list controls as plain JSON.
public struct SavedView: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var preferences: [String: JSONValue]
    public init(id: String, name: String, preferences: [String: JSONValue]) {
        self.id = id; self.name = name; self.preferences = preferences
    }
}

/// What one list stores (`SavedViewsKind`).
public struct SavedViewsKind: Sendable {
    public var storageKey: String
    /// "pullRequest" or "issue": picks the menu's words.
    public var list: String
    public var placeholder: String
    public var suggestedName: @Sendable ([String: JSONValue]) -> String

    /// `ISSUE_SAVED_VIEWS` (issueSavedViews.ts).
    public static let issues = SavedViewsKind(storageKey: "t3.issues.savedViews", list: "issue", placeholder: "Issues Assigned to Me") {
        $0["who"] == .string("assigned") ? "Issues Assigned to Me" : ""
    }

    /// `PULL_REQUEST_SAVED_VIEWS` (pullRequestSavedViews.ts).
    public static let pullRequests = SavedViewsKind(storageKey: "t3.pullRequests.savedViews", list: "pullRequest", placeholder: "PRs Requesting My Review") {
        $0["involvement"] == .string("reviewing") ? "PRs Requesting My Review" : ""
    }
}

public enum SavedViews {
    /// `SAVED_VIEW_NAME_MAX_LENGTH`.
    public static let nameMaxLength = 80

    public static func load(_ kind: SavedViewsKind, defaults: UserDefaults = .standard) -> [SavedView] {
        guard let data = defaults.data(forKey: kind.storageKey),
              let views = try? JSONDecoder().decode([SavedView].self, from: data) else { return [] }
        return views.filter { !$0.id.isEmpty && !$0.name.isEmpty && $0.name.count <= nameMaxLength }
    }

    @discardableResult
    public static func save(_ views: [SavedView], _ kind: SavedViewsKind, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(views) else { return false }
        defaults.set(data, forKey: kind.storageKey)
        return true
    }

    /// `issueViewMatches` and `pullRequestViewMatches`: the same controls, labels in any order.
    public static func matches(_ view: SavedView, _ preferences: [String: JSONValue]) -> Bool {
        normalized(view.preferences) == normalized(preferences)
    }

    static func normalized(_ p: [String: JSONValue]) -> [String: JSONValue] {
        p.compactMapValues { v -> JSONValue? in
            switch v {
            case .null: return nil
            case .string(let s) where s.isEmpty: return nil
            case .array(let a) where a.isEmpty: return nil
            case .array(let a): return .array(a.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") })
            default: return v
            }
        }
    }

    /// `savedViewNameError`.
    public static func nameError(_ name: String, views: [SavedView], editingId: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name for this view." }
        if trimmed.count > nameMaxLength { return "Use \(nameMaxLength) characters or fewer." }
        return views.contains { $0.id != editingId && $0.name.lowercased() == trimmed.lowercased() } ? "A view with this name already exists." : nil
    }
}

/// The Views button and its menu (`SavedViewsMenu`): the bookmark, the selected view's name or
/// "Views", `*` when the controls moved off it, a chevron; the menu lists the views, then Save
/// current view, Update saved view, Rename view and Delete view.
@MainActor
public final class SavedViewsMenuController {
    public let button = ButtonView("Views", icon: .bookmark, variant: .outline).menuTrigger()
    private let kind: SavedViewsKind
    private var views: [SavedView]
    private var selectedId: String?
    /// The page's controls right now, as a view would keep them.
    public var preferences: [String: JSONValue] = [:] { didSet { refresh() } }
    public var onApply: (([String: JSONValue]) -> Void)?
    /// The button's width changed; the page lays out again.
    public var onResize: (() -> Void)?
    private var modal: ModalHost?

    public init(kind: SavedViewsKind) {
        self.kind = kind
        views = SavedViews.load(kind)
        button.trailingIcon = .chevronDown
        button.action = { [weak self] in self?.showMenu() }
        refresh()
    }

    var savedViewsLabel: String { kind.list == "pullRequest" ? "Saved pull request views" : "Saved issue views" }

    private var selected: SavedView? {
        views.first { $0.id == selectedId } ?? views.first { SavedViews.matches($0, preferences) }
    }

    private var modified: Bool { selected.map { !SavedViews.matches($0, preferences) } ?? false }

    private func refresh() {
        if let s = selected, selectedId != s.id { selectedId = s.id }
        let title = (selected?.name ?? "Views") + (modified ? " *" : "")
        if button.title != title {
            button.title = title
            onResize?()
        }
        button.setAccessibilityLabel(savedViewsLabel)
        button.toolTip = selected?.name ?? savedViewsLabel
    }

    private func persist(_ next: [SavedView]) -> Bool {
        views = next
        let ok = SavedViews.save(next, kind)
        refresh()
        return ok
    }

    func showMenu() {
        var items: [MenuItem] = views.map { view in
            var item = MenuItem(view.name, icon: selected?.id == view.id && !modified ? .check : .bookmark)
            item.tooltip = view.name
            item.action = { [weak self] in
                self?.selectedId = view.id
                self?.onApply?(view.preferences)
            }
            return item
        }
        if !views.isEmpty { items.append(.separator) }
        var save = MenuItem("Save current view…", icon: .plus)
        save.action = { [weak self] in guard let self else { return }; self.edit(id: nil, name: self.kind.suggestedName(self.preferences)) }
        items.append(save)
        if let s = selected {
            if modified {
                var update = MenuItem("Update saved view")
                update.action = { [weak self] in
                    guard let self else { return }
                    _ = self.persist(self.views.map { $0.id == s.id ? SavedView(id: $0.id, name: $0.name, preferences: self.preferences) : $0 })
                }
                items.append(update)
            }
            var rename = MenuItem("Rename view…")
            rename.action = { [weak self] in self?.edit(id: s.id, name: s.name) }
            items.append(rename)
            var delete = MenuItem("Delete view")
            delete.isDestructive = true
            delete.action = { [weak self] in
                guard let self else { return }
                if self.persist(self.views.filter { $0.id != s.id }) { self.selectedId = nil; self.refresh() }
            }
            items.append(delete)
        }
        MenuPopupView.show(items, from: button, placement: .dropdown)
    }

    /// The name dialog: "Save issue view" or "Rename issue view".
    private func edit(id: String?, name: String) {
        guard let window = button.window else { return }
        let pr = kind.list == "pullRequest"
        let dialog = DialogView(kind: .dialog, title: id == nil ? (pr ? "Save PR view" : "Save issue view") : (pr ? "Rename PR view" : "Rename issue view"),
                                message: "Save your search, filters, and sort order on this device.")
        let input = InputView(placeholder: kind.placeholder)
        input.text = name
        input.setAccessibilityLabel("View name")
        let error = LabelView("", font: DSFont.ui(14), color: Themed.color(\.destructiveForeground))
        let fields = SavedViewNameFields(input: input, error: error)
        let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
        let saveButton = ButtonView("Save", variant: .default, size: .sm)
        dialog.panelContent = [fields]
        dialog.footerButtons = [cancel, saveButton]
        let check = { [weak self] in
            guard let self else { return }
            let message = SavedViews.nameError(input.text, views: self.views, editingId: id)
            error.text = input.text.isEmpty ? "" : (message ?? "")
            saveButton.isEnabled = message == nil
            fields.needsLayout = true
        }
        input.onChange = { _ in check() }
        check()
        let host = ModalHost.present(dialog, in: window)
        modal = host
        host.onDismiss = { [weak self] in self?.modal = nil }
        cancel.action = { [weak host] in host?.close() }
        let submit: @MainActor @Sendable () -> Void = { [weak self, weak host] in
            guard let self, SavedViews.nameError(input.text, views: self.views, editingId: id) == nil else { return }
            let trimmed = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let newId = id ?? UUID().uuidString.lowercased()
            if let id, !self.views.contains(where: { $0.id == id }) { return } // removed meanwhile: the name stays typed
            let next = id == nil ? self.views + [SavedView(id: newId, name: trimmed, preferences: self.preferences)]
                : self.views.map { $0.id == id ? SavedView(id: $0.id, name: trimmed, preferences: $0.preferences) : $0 }
            guard self.persist(next) else { return }
            self.selectedId = newId
            self.refresh()
            host?.close()
        }
        saveButton.action = submit
        input.onSubmit = submit
        DispatchQueue.main.async { [weak input] in input?.window?.makeFirstResponder(input) }
    }
}

/// "View name", the field, and the error under it.
final class SavedViewNameFields: DSView {
    private let label = LabelView("View name", font: DSFont.ui(14, weight: .medium))
    let input: InputView
    let error: LabelView
    init(input: InputView, error: LabelView) {
        self.input = input
        self.error = error
        super.init(frame: .zero)
        label.lineHeight = 20
        error.lineHeight = 20
        [label, input, error].forEach(addSubview)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20 + 8 + 36 + (error.text.isEmpty ? 0 : 8 + 20)) }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        input.frame = NSRect(x: 0, y: 28, width: bounds.width, height: 36)
        error.frame = NSRect(x: 0, y: 72, width: bounds.width, height: 20)
        invalidateIntrinsicContentSize()
    }
}
