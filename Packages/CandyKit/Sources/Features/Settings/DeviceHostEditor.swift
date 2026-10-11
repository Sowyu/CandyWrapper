import AppKit
import DesignSystem
import T3Protocol

/// deviceHostsSettings.logic.ts:4-43; preserves each environment's IDs and unrelated hosts.
public enum DeviceHostEditing {
    public static func draft(id: String, label: String, target: String, identity: String, port: String) -> JSONValue? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !target.isEmpty, !target.hasPrefix("-"),
              target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        var result: [String: JSONValue] = ["id": .string(id), "label": .string(label), "target": .string(target)]
        if !identity.isEmpty { result["identityFile"] = .string(identity) }
        if !port.isEmpty {
            guard let value = Int(port), (1...65535).contains(value) else { return nil }
            result["port"] = .number(Double(value))
        }
        return .object(result)
    }
    public static func update(_ hosts: [JSONValue], host: JSONValue, original: JSONValue, remove: Bool) throws -> [JSONValue] {
        func destination(_ value: JSONValue) throws -> JSONValue? {
            let matches = hosts.filter { $0["target"] == value["target"] && $0["port"] == value["port"] && $0["identityFile"] == value["identityFile"] }
            guard matches.count <= 1 else { throw DeviceHostEditError.ambiguous }
            return matches.first
        }
        let existing = try hosts.first { $0["id"] == original["id"] } ?? destination(original) ?? (remove ? nil : destination(host))
        if remove { return hosts.filter { $0["id"] != existing?["id"] } }
        guard let existing else { return hosts + [host] }
        var fields = host.objectValue ?? [:]; fields["id"] = existing["id"]
        return hosts.map { $0["id"] == existing["id"] ? .object(fields) : $0 }
    }
    public enum DeviceHostEditError: Error, CustomStringConvertible {
        case ambiguous
        public var description: String { "Multiple hosts match this SSH destination. Select the environment to edit its hosts." }
    }
}

/// DeviceHostEditor.tsx:42-226, using the shared modal and field controls.
@MainActor
final class DeviceHostEditor {
    let dialog: DialogView
    private let form = DeviceHostEditorForm()
    private let save = ButtonView("Save host")
    private let cancel = ButtonView("Cancel", variant: .ghost)
    private weak var host: ModalHost?
    private let context: SettingsPageContext
    private let original: JSONValue
    private var task: Task<Void, Never>?
    private var busy = false { didSet { save.isEnabled = !busy && validDraft != nil; cancel.isEnabled = !busy; form.test.isEnabled = !busy && validDraft != nil; form.inputs.forEach { $0.isEnabled = !busy } } }
    init(context: SettingsPageContext, original: JSONValue?) {
        self.context = context
        self.original = original ?? .object(["id": .string(UUID().uuidString), "label": .string(""), "target": .string("")])
        dialog = DialogView(title: original == nil ? "Add device host" : "Edit device host", message: "Connect from \(context.scope.targets.count) selected environments. Hosts on the same machine are skipped.")
        for (input, key) in zip(form.inputs, ["label", "target", "identityFile", "port"]) {
            input.text = self.original[key]?.stringValue ?? self.original[key]?.doubleValue.map { String(Int($0)) } ?? ""
        }
        dialog.panelContent = [form]; dialog.footerButtons = [cancel, save]
        cancel.action = { [weak self] in self?.host?.close() }
        save.action = { [weak self] in self?.run(check: false) }
        form.test.action = { [weak self] in self?.run(check: true) }
        form.inputs.forEach { input in input.onChange = { [weak self] _ in
            guard let self else { return }; self.save.isEnabled = !self.busy && self.validDraft != nil; self.form.test.isEnabled = self.save.isEnabled
        } }
        save.isEnabled = validDraft != nil; form.test.isEnabled = save.isEnabled
    }
    func present() {
        host = context.presentDialog?(dialog)
        let previous = host?.onDismiss
        host?.onDismiss = { [weak self] in self?.task?.cancel(); previous?() }
    }
    private var validDraft: JSONValue? {
        DeviceHostEditing.draft(id: original["id"]?.stringValue ?? "", label: form.inputs[0].text,
            target: form.inputs[1].text, identity: form.inputs[2].text, port: form.inputs[3].text)
    }
    private func run(check: Bool) {
        guard !busy, context.scope.canWrite, !context.scope.isProjectScope, let request = context.request,
              let draft = DeviceHostEditing.draft(id: original["id"]?.stringValue ?? UUID().uuidString,
                label: form.inputs[0].text, target: form.inputs[1].text, identity: form.inputs[2].text, port: form.inputs[3].text) else {
            form.status.text = "Enter a name, SSH target and valid port (1–65535)."; return
        }
        let targets = context.scope.targets
        busy = true; form.status.text = check ? "Checking environments…" : "Saving…"
        task = Task { [weak self] in
            guard let self else { return }
            var messages: [String] = []; var failed = false
            for target in targets {
                do {
                    try Task.checkCancellation()
                    if check {
                        let result = try await request(target.environmentId, "device.testHost", draft)
                        messages.append("\(target.label): \(result["kind"]?.stringValue == "local" ? "Already available locally" : "Connected")")
                    } else {
                        let current = context.scope.targets.first { $0.environmentId == target.environmentId }?.settings["deviceHosts"].arrayValue ?? []
                        let hosts = try DeviceHostEditing.update(current, host: draft, original: original, remove: false)
                        let result = try await request(target.environmentId, "server.updateSettings", .object(["patch": .object(["deviceHosts": .array(hosts)])]))
                        context.applySettings?(target.environmentId, result)
                    }
                } catch { if Task.isCancelled { break }; failed = true; messages.append("\(target.label): \(error)") }
            }
            busy = false
            guard !Task.isCancelled else { return }
            form.status.text = messages.joined(separator: "\n")
            if !check && !failed { host?.close() }
        }
    }
}

final class DeviceHostEditorForm: DSView {
    let inputs = [InputView(placeholder: "Mac mini"), InputView(placeholder: "user@host or SSH alias"), InputView(placeholder: "SSH config default"), InputView(placeholder: "Default")]
    private let labels = ["Name", "SSH target", "Identity file", "Port"].map { LabelView($0, font: DSFont.ui(14)) }
    let test = ButtonView("Test connection", variant: .outline, size: .sm)
    let status = TextBlockView("Check access before saving", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    override init(frame: NSRect) {
        super.init(frame: frame)
        (inputs as [NSView] + labels + [test, status]).forEach(addSubview)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 440, height: 380) }
    override func layout() {
        super.layout()
        for i in 0..<inputs.count {
            labels[i].frame = NSRect(x: 0, y: CGFloat(i) * 66, width: bounds.width, height: 20)
            inputs[i].frame = NSRect(x: 0, y: CGFloat(i) * 66 + 24, width: bounds.width, height: 32)
        }
        test.frame = NSRect(x: max(0, bounds.width - 140), y: 268, width: 140, height: 28)
        status.frame = NSRect(x: 0, y: 306, width: bounds.width, height: 72)
    }
}
