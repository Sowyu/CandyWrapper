import Foundation
import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// shared/assistantCitations.ts:38-112 and contracts/assistantCitations.ts:4-35.
/// Offsets refer to rendered UTF-16 text. Keep them untouched when editing a comment.
public struct ThreadAssistantCitation: Equatable, Sendable {
    public var environmentId: String
    public var threadId: String
    public var messageId: String
    public var text: String
    public var start: Int
    public var end: Int
    public var prefix: String
    public var suffix: String
    public var comment: String?
    public var label: String {
        let value = (comment?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? text
        let compact = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let ns = compact as NSString
        return ns.length > 64 ? ns.substring(to: 64) + "…" : compact
    }
    public static func parse(_ href: String) -> Self? {
        guard href.hasPrefix("t3-citation://v1/"), href.utf16.count <= 160_000,
              let parts = URLComponents(string: href), parts.scheme == "t3-citation", parts.host == "v1",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        let path = parts.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false).compactMap { String($0).removingPercentEncoding }
        guard path.count == 3, path.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 512 }) else { return nil }
        var query: [String: String] = [:]
        // URLSearchParams decodes '+' as a space; URLComponents does not.
        for pair in (parts.percentEncodedQuery ?? "").split(separator: "&") {
            let bits = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard bits.count == 2, let key = String(bits[0]).removingPercentEncoding,
                  let value = String(bits[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  query[key] == nil else { return nil }
            query[key] = value
        }
        let required: Set<String> = ["text", "start", "end", "prefix", "suffix"]
        guard Set(query.keys) == required || Set(query.keys) == required.union(["comment"]),
              let text = query["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 8000,
              let from = query["start"], from.range(of: "^[0-9]{1,16}$", options: .regularExpression) != nil,
              let to = query["end"], to.range(of: "^[0-9]{1,16}$", options: .regularExpression) != nil,
              let start = Int(from), let end = Int(to), start >= 0, end > start, end <= 9_007_199_254_740_991,
              let prefix = query["prefix"], prefix.utf16.count <= 32, let suffix = query["suffix"], suffix.utf16.count <= 32,
              (query["comment"]?.utf16.count ?? 0) <= 8000 else { return nil }
        return Self(environmentId: path[0], threadId: path[1], messageId: path[2], text: text, start: start, end: end, prefix: prefix, suffix: suffix, comment: query["comment"])
    }
    public var href: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let path = [environmentId, threadId, messageId].map(encode).joined(separator: "/")
        var values = [("text", text), ("start", String(start)), ("end", String(end)), ("prefix", prefix), ("suffix", suffix)]
        if let comment { values.append(("comment", comment)) }
        return "t3-citation://v1/" + path + "?" + values.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
    }
    public var markdown: String { "[Assistant quote](\(href))" }
    public func withComment(_ value: String) -> Self {
        var copy = self
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.comment = trimmed.isEmpty ? nil : trimmed
        return copy
    }
}

@MainActor
public enum ThreadAssistantCitationEditor {
    /// The dialog for a citation chip already in the composer or a sent message. A fresh Cite opens
    /// `AssistantCitationCommentPopup` under the selection instead.
    // ponytail: a composer chip edits its comment in this dialog; T3 opens the same popover from the chip's pencil. Move it when the composer chips get their pencil
    public static func present(_ citation: ThreadAssistantCitation, in window: NSWindow, save: (@MainActor (ThreadAssistantCitation) -> Void)? = nil, openSource: (@MainActor () -> Void)? = nil) {
        let dialog = DialogView(title: "Assistant quote", message: citation.text)
        dialog.maxWidth = 400
        let comment = TextareaView(placeholder: "Add an optional comment...", text: citation.comment ?? "")
        comment.setAccessibilityLabel("Comment on selected text")
        let cancel = ButtonView("Cancel", variant: .outline, size: .xs)
        let commit = ButtonView("Save", size: .xs)
        let source = ButtonView("Open source", icon: .arrowUpRight, variant: .ghost, size: .xs)
        if save != nil { dialog.panelContent = [comment]; dialog.footerButtons = [cancel, commit] }
        else { dialog.message = citation.text + (citation.comment.map { "\n\nComment: " + $0 } ?? "") }
        if openSource != nil { dialog.footerButtons.insert(source, at: 0) }
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        source.action = { [weak host] in host?.close(); openSource?() }
        let submit: @MainActor () -> Void = { [weak host, weak comment] in
            guard let comment, comment.text.utf16.count <= 8000 else { return }
            save?(citation.withComment(comment.text)); host?.close()
        }
        commit.action = submit
        comment.onChange = { [weak commit] text in commit?.isEnabled = text.utf16.count <= 8000; commit?.title = text.utf16.count <= 8000 ? "Save" : "Shorten comment" }
        comment.onSubmit = submit
    }
}

/// `AssistantCitationCommentEditor` (AssistantCitationCommentEditor.tsx:6-102) in the citation chip's popover
/// (AssistantCitationChip.tsx:167-240): `PopoverPopup width="md" padding="compact"`, anchored under the
/// selection's last line, `side="bottom" align="end"`. Enter saves, Command-Enter saves and sends,
/// Shift-Enter starts a new line, Escape closes. Cancel removes a fresh citation (`removeOnCancel`).
@MainActor
public final class AssistantCitationCommentEditorView: DSView {
    static let maxComment = 8000
    static let width: CGFloat = 320 - 2 - 24
    let input = TextareaView(placeholder: "Add an optional comment...")
    private let error = TextBlockView("Comments can contain up to 8,000 characters.", font: DSFont.ui(12), lineHeight: 16,
                                      color: Themed.color(\.destructive))
    let cancel = ButtonView("Cancel", variant: .outline, size: .xs)
    let save = ButtonView("Save", size: .xs)
    var onSave: ((String) -> Void)?
    var onSaveAndSend: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onEscape: (() -> Void)?
    var onHeightChange: (() -> Void)?

    public init(comment: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        input.bare = true
        input.text = comment ?? ""
        input.setAccessibilityLabel("Comment on selected text")
        input.setAccessibilityHelp("Enter to save the citation comment; Command/Ctrl+Enter to save and send; Shift+Enter for a new line.")
        error.isHidden = true
        [input, error, cancel, save].forEach(addSubview)
        cancel.action = { [weak self] in self?.onCancel?() }
        save.action = { [weak self] in self?.submit(send: false) }
        input.onChange = { [weak self] _ in self?.update() }
        update()
    }

    var tooLong: Bool { input.text.utf16.count > Self.maxComment }

    private func update() {
        error.isHidden = !tooLong
        save.isEnabled = !tooLong
        save.title = tooLong ? "Shorten comment" : "Save"
        input.isInvalid = tooLong
        invalidateIntrinsicContentSize()
        needsLayout = true
        onHeightChange?()
    }

    func submit(send: Bool) {
        guard !tooLong else { return }
        if send { onSaveAndSend?(input.text) } else { onSave?(input.text) }
    }

    /// `onKeyDown` on the textarea: Enter without Shift submits, unless an input method is composing.
    func handle(_ key: PopupKey) -> Bool {
        switch key {
        case .escape: onEscape?(); return true
        case .enter:
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            guard !flags.contains(.shift), !input.hasMarkedText else { return false }
            submit(send: flags.contains(.command) || flags.contains(.control))
            return true
        default: return false
        }
    }

    private func errorHeight(_ width: CGFloat) -> CGFloat { error.isHidden ? 0 : 4 + error.height(forWidth: width) }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: input.height(forWidth: Self.width) + errorHeight(Self.width) + 8 + 24)
    }

    public override func layout() {
        super.layout()
        let h = input.height(forWidth: bounds.width), eh = errorHeight(bounds.width)
        input.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        error.frame = NSRect(x: 0, y: h + 4, width: bounds.width, height: max(0, eh - 4))
        let y = h + eh + 8
        let sw = save.intrinsicContentSize.width, cw = cancel.intrinsicContentSize.width
        save.frame = NSRect(x: bounds.width - sw, y: y, width: sw, height: 24)
        cancel.frame = NSRect(x: save.frame.minX - 8 - cw, y: y, width: cw, height: 24)
    }
}

/// Where a selection's comment popover anchors: the selection's last line in `view`'s coordinates.
public struct AssistantSelectionAnchor {
    public weak var view: NSView?
    public var rect: CGRect
    public init(view: NSView?, rect: CGRect) { self.view = view; self.rect = rect }
}

@MainActor
public enum AssistantCitationCommentPopup {
    /// Opens the editor under `anchor`. `save` gets the edited citation and whether to send; `remove` drops the
    /// fresh chip (Cancel). Escape closes and keeps the chip as inserted; a click outside commits a changed
    /// comment (`resolveAssistantCitationCommentDismissal`).
    @discardableResult
    public static func present(_ citation: ThreadAssistantCitation, anchor: AssistantSelectionAnchor,
                               save: @escaping @MainActor (ThreadAssistantCitation, _ send: Bool) -> Void,
                               remove: @escaping @MainActor () -> Void,
                               restoreFocus: @escaping @MainActor () -> Void) -> OpenPopup? {
        guard let view = anchor.view, let host = view.popupHost else { return nil }
        let editor = AssistantCitationCommentEditorView(comment: citation.comment)
        let popover = PopoverView(content: editor, padding: .compact, width: .md)
        popover.setAccessibilityLabel("Edit citation comment")
        popover.onKey = { [weak editor] key in editor?.handle(key) ?? false }
        let placement = PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .end)
        let popup = host.open(popover, trigger: view, anchorRect: anchor.rect, placement: placement, motion: .popover,
                              pressesTrigger: false, returnsFocus: false)
        var settled = false
        let finish: @MainActor (() -> Void) -> Void = { [weak host, weak popup] run in
            guard !settled else { return }
            settled = true
            run()
            if let popup { host?.close(popup, returnFocus: false) }
            restoreFocus()
        }
        editor.onSave = { comment in finish { save(citation.withComment(comment), false) } }
        editor.onSaveAndSend = { comment in finish { save(citation.withComment(comment), true) } }
        editor.onCancel = { finish(remove) }
        editor.onEscape = { finish {} }
        editor.onHeightChange = { [weak host, weak popup] in if let popup { host?.reposition(popup) } }
        popup.onClose = { [weak editor] in
            guard !settled, let editor else { return }
            settled = true
            let draft = editor.input.text
            // ponytail: a too-long draft closes on an outside click; T3 keeps the popover open. Needs a veto hook in PopupHost
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) != (citation.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
               !editor.tooLong {
                save(citation.withComment(draft), false)
            }
        }
        DispatchQueue.main.async { [weak editor] in
            guard let editor, let window = editor.window else { return }
            window.makeFirstResponder(editor.input)
        }
        return popup
    }
}

/// T3 3814 citationProcedure.ts:36-91. Older pages populate visible turn items.
public enum CitationHistory {
    public enum Step: Equatable, Sendable {
        case waiting, loadEarlier
        case found(entryId: String, runId: String?)
        case failed(title: String, message: String)
    }
    public static let couldNotLoad = Step.failed(title: "Could not load the cited response",
        message: "Load earlier turns, then click the citation to try again. Your saved quote is unchanged.")
    public static let unavailable = Step.failed(title: "The cited response is unavailable",
        message: "It may have been removed. The selected text is still saved in your citation.")

    public static func step(messageId: String, projection: ThreadProjection?, history: ThreadHistoryMeta,
                            status: ThreadSyncStatus, pages: Int) -> Step {
        guard !history.loading else { return .waiting }
        if history.error != nil { return couldNotLoad }
        if status == .deleted { return unavailable }
        guard let projection else { return .waiting }
        if let item = projection.visibleTurnItems.first(where: {
            ($0.item.type == .assistantMessage || $0.item.type == .userMessage) && $0.item.messageId?.rawValue == messageId
        })?.item {
            guard item.type == .assistantMessage else {
                return .failed(title: "The citation does not refer to an assistant response",
                               message: "The selected text is still saved in your citation.")
            }
            return .found(entryId: messageId, runId: item.runId?.rawValue)
        }
        guard status == .live else { return .waiting }
        guard history.hasMoreHistory, history.historyCursor != nil else { return unavailable }
        return pages >= 20 ? couldNotLoad : .loadEarlier
    }
}
