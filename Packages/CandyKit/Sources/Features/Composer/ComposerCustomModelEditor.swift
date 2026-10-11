import AppKit
import DesignSystem
import T3Protocol

/// customModelEditor.logic.ts:170-278. Keep unknown descriptive fields while
/// removing prompt-injected choices that custom runtime profiles cannot send.
struct ComposerCustomModelDraft {
    var slug: String
    var name: String
    var descriptors: [[String: JSONValue]]
    init(_ entry: JSONValue) {
        slug = entry.stringValue ?? entry["slug"]?.stringValue ?? ""
        name = entry["name"]?.stringValue ?? ""
        if name == slug { name = "" }
        descriptors = (entry["capabilities"]?["optionDescriptors"]?.arrayValue ?? []).compactMap(\.objectValue).map { descriptor in
            var descriptor = descriptor
            let injected = Set((descriptor["promptInjectedValues"]?.arrayValue ?? []).compactMap(\.stringValue))
            let options = (descriptor["options"]?.arrayValue ?? []).filter { !injected.contains($0["id"]?.stringValue ?? "") }
            let current = options.first { $0["id"] == descriptor["currentValue"] } ?? options.first { $0["isDefault"]?.boolValue == true }
            if descriptor["type"]?.stringValue == "select" {
                descriptor["options"] = .array(options.map { option in
                    var o = option.objectValue ?? [:]
                    o["isDefault"] = .bool(option["id"] == current?["id"])
                    return .object(o)
                })
            }
            descriptor["promptInjectedValues"] = nil
            return descriptor
        }
    }
    var error: String? {
        var ids = Set<String>()
        for (i, d) in descriptors.enumerated() {
            let position = "Option \(i + 1)", id = (d["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { return "\(position) needs an id." }
            if !ids.insert(id).inserted { return "\(position): id \"\(id)\" is used twice." }
            if (d["label"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "\(position) needs a label." }
            if d["type"]?.stringValue != "select" { continue }
            let options = d["options"]?.arrayValue ?? []
            if options.isEmpty { return "\(position) needs at least one choice." }
            var choices = Set<String>()
            for choice in options {
                let id = (choice["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if id.isEmpty { return "\(position) has a choice without a value." }
                if !choices.insert(id).inserted { return "\(position): choice \"\(id)\" is used twice." }
            }
        }
        return nil
    }
    var definition: JSONValue {
        let values = descriptors.map { descriptor -> JSONValue in
            var d = descriptor
            for key in ["id", "label"] { d[key] = .string((d[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
            if d["type"]?.stringValue == "select" {
                let options = (d["options"]?.arrayValue ?? []).map { choice -> JSONValue in
                    var c = choice.objectValue ?? [:]
                    let id = (c["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = (c["label"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    c["id"] = .string(id); c["label"] = .string(label.isEmpty ? id : label)
                    if c["isDefault"]?.boolValue != true { c["isDefault"] = nil }
                    return .object(c)
                }
                d["options"] = .array(options)
                d["currentValue"] = options.first { $0["isDefault"]?.boolValue == true }?["id"]
            } else { d["options"] = nil; if d["currentValue"]?.boolValue == nil { d["currentValue"] = nil } }
            return .object(d)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .object(["slug": .string(slug), "name": .string(trimmed.isEmpty ? slug : trimmed),
                        "capabilities": values.isEmpty ? .null : .object(["optionDescriptors": .array(values)])])
    }
}

/// Inline custom-model form, sharing the provider page's input and button components.
// ponytail: compact native form; match the official wrapping layout in the visual pass.
final class ComposerCustomModelEditor: DSView {
    var onSave: ((JSONValue) -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChange: (() -> Void)?
    private let driver: String
    private let builtins: [ServerProviderModel]
    private var draft: ComposerCustomModelDraft
    private var rows: [[NSView]] = []
    private var error: String?
    init(entry: JSONValue, driver: String = "", builtins: [ServerProviderModel] = []) {
        self.driver = driver; self.builtins = builtins.filter { !$0.isCustom && !$0.optionDescriptors.isEmpty }
        draft = ComposerCustomModelDraft(entry); super.init(frame: .zero); rebuild()
    }
    private func label(_ text: String) -> LabelView { LabelView(text, font: DSFont.ui(12), color: Themed.color(\.mutedForeground)) }
    private func input(_ placeholder: String, _ value: String, change: @escaping @MainActor @Sendable (String) -> Void) -> InputView {
        let field = InputView(placeholder: placeholder, text: value, size: .sm)
        field.setAccessibilityLabel(placeholder)
        field.onChange = change
        field.onCommand = { [weak self] command in
            guard command == #selector(NSResponder.cancelOperation(_:)) else { return false }
            self?.onCancel?(); return true
        }
        return field
    }
    private func button(_ title: String, _ action: @escaping @MainActor @Sendable () -> Void) -> ButtonView {
        let b = ButtonView(title, variant: .ghostMuted, size: .xs); b.action = action; return b
    }
    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }; rows = []
        rows.append([label("Display name")])
        rows.append([input(draft.slug, draft.name) { [weak self] in self?.draft.name = $0 }])
        if !builtins.isEmpty {
            let copy = SelectView(options: builtins.map(\.name), selected: nil, placeholder: "Copy from…", size: .compact)
            copy.setAccessibilityLabel("Copy options from a built-in model")
            copy.onChange = { [weak self] index in
                guard let self, self.builtins.indices.contains(index),
                      let data = try? JSONEncoder().encode(self.builtins[index].optionDescriptors),
                      let descriptors = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
                self.draft.descriptors = ComposerCustomModelDraft(.object(["capabilities": .object(["optionDescriptors": descriptors])])).descriptors
                self.rebuild()
            }
            rows.append([label("Options shown in the composer"), copy])
        } else { rows.append([label("Options shown in the composer")]) }
        if draft.descriptors.isEmpty { rows.append([label("No custom options. The composer uses the provider's default options.")]) }
        for i in draft.descriptors.indices {
            let d = draft.descriptors[i]
            let type = SelectView(options: ["Select", "Boolean"], selected: d["type"]?.stringValue == "boolean" ? 1 : 0, size: .compact)
            type.onChange = { [weak self] value in
                self?.draft.descriptors[i]["type"] = .string(value == 1 ? "boolean" : "select"); self?.rebuild()
            }
            rows.append([label("Option \(i + 1)"), input("Option id", d["id"]?.stringValue ?? "") { [weak self] in self?.draft.descriptors[i]["id"] = .string($0) }, type,
                         button("Remove option") { [weak self] in self?.draft.descriptors.remove(at: i); self?.rebuild() }])
            rows.append([input("Label", d["label"]?.stringValue ?? "") { [weak self] in self?.draft.descriptors[i]["label"] = .string($0) }])
            if d["type"]?.stringValue == "select" {
                for (j, choice) in (d["options"]?.arrayValue ?? []).enumerated() {
                    let toggle = SwitchView(isOn: choice["isDefault"]?.boolValue ?? false, size: .sm)
                    toggle.setAccessibilityLabel("Default choice")
                    toggle.onChange = { [weak self] value in
                        guard let self else { return }
                        self.draft.descriptors[i]["options"] = .array((self.draft.descriptors[i]["options"]?.arrayValue ?? []).enumerated().map { n, entry in
                            var o = entry.objectValue ?? [:]; o["isDefault"] = .bool(n == j && value); return .object(o)
                        }); self.rebuild()
                    }
                    rows.append([input("Choice value", choice["id"]?.stringValue ?? "") { [weak self] in self?.choice(i, j, "id", $0) },
                                 input("Choice label", choice["label"]?.stringValue ?? "") { [weak self] in self?.choice(i, j, "label", $0) }, toggle, label("Default"),
                                 button("×") { [weak self] in
                                     guard let self else { return }; var values = self.draft.descriptors[i]["options"]?.arrayValue ?? []
                                     values.remove(at: j); self.draft.descriptors[i]["options"] = .array(values); self.rebuild()
                                 }])
                }
                rows.append([button("Add choice") { [weak self] in
                    guard let self else { return }
                    var choices = self.draft.descriptors[i]["options"]?.arrayValue ?? []
                    choices.append(.object(["id": .string(""), "label": .string("")]))
                    self.draft.descriptors[i]["options"] = .array(choices); self.rebuild()
                }])
            }
        }
        let presets = ComposerCustomModelPresets.descriptors(driver)
        if !presets.isEmpty {
            let preset = SelectView(options: presets.map { $0["id"]?.stringValue ?? "" }, selected: nil, placeholder: "Add option…", size: .compact)
            preset.onChange = { [weak self] index in
                guard let self else { return }
                self.draft.descriptors.append(presets[index]); self.rebuild()
            }
            rows.append([preset])
        }
        rows.append([button("Custom option") { [weak self] in self?.draft.descriptors.append(["id": .string(""), "label": .string(""), "type": .string("select"), "options": .array([])]); self?.rebuild() }])
        if let error { rows.append([label(error)]) }
        rows.append([button("Save") { [weak self] in
            guard let self else { return }
            if let error = self.draft.error { self.error = error; self.rebuild() } else { self.onSave?(self.draft.definition) }
        }, button("Cancel") { [weak self] in self?.onCancel?() }])
        rows.flatMap { $0 }.forEach(addSubview)
        needsLayout = true; invalidateIntrinsicContentSize(); onHeightChange?()
    }
    private func choice(_ i: Int, _ j: Int, _ key: String, _ value: String) {
        var choices = draft.descriptors[i]["options"]?.arrayValue ?? []
        var c = choices[j].objectValue ?? [:]; c[key] = .string(value); choices[j] = .object(c)
        draft.descriptors[i]["options"] = .array(choices)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 400, height: CGFloat(rows.count) * 36 + 24) }
    override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.muted, 0.2).cgColor(in: self)
        layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        layer?.borderWidth = 1; layer?.cornerRadius = 6
    }
    override func layout() {
        super.layout()
        for (i, row) in rows.enumerated() {
            let fields = row.filter { $0 is InputView }.count
            let fixed = row.filter { !($0 is InputView) }.reduce(CGFloat(0)) { $0 + max(30, min(150, $1.intrinsicContentSize.width)) }
            let fieldWidth = max(40, (bounds.width - 24 - fixed - CGFloat(max(0, row.count - 1)) * 8) / CGFloat(max(1, fields)))
            var x: CGFloat = 12
            for view in row {
                let width = view is InputView ? fieldWidth : max(30, min(150, view.intrinsicContentSize.width))
                view.frame = NSRect(x: x, y: 12 + CGFloat(i) * 36, width: row.count == 1 && view is LabelView ? bounds.width - 24 : width, height: 28)
                x += width + 8
            }
        }
    }
}

/// customModelEditor.logic.ts:38-120: only ids consumed by each provider driver.
enum ComposerCustomModelPresets {
    static func descriptors(_ driver: String) -> [[String: JSONValue]] {
        func select(_ id: String, _ label: String, _ choices: [(String, String)], _ current: String) -> [String: JSONValue] {
            ["id": .string(id), "label": .string(label), "type": .string("select"), "options": .array(choices.map {
                .object(["id": .string($0.0), "label": .string($0.1), "isDefault": .bool($0.0 == current)])
            })]
        }
        func boolean(_ id: String, _ label: String) -> [String: JSONValue] { ["id": .string(id), "label": .string(label), "type": .string("boolean")] }
        let effort = [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra High")]
        switch driver {
        case "codex": return [select("reasoningEffort", "Reasoning", effort, "medium"), select("serviceTier", "Speed", [("default", "Standard"), ("fast", "Fast")], "default")]
        case "claudeAgent": return [select("effort", "Reasoning", effort + [("max", "Max")], "high"), boolean("fastMode", "Fast Mode"), boolean("thinking", "Thinking")]
        case "cursor": return [select("reasoning", "Reasoning", effort, "medium"), boolean("fastMode", "Fast Mode"), boolean("thinking", "Thinking")]
        case "grok": return [select("reasoningEffort", "Reasoning", effort, "medium")]
        case "pi": return [select("thinking", "Thinking", [("off", "Off"), ("minimal", "Minimal")] + effort + [("max", "Max")], "medium")]
        case "opencode": return [select("variant", "Reasoning", effort, "medium"), select("agent", "Agent", [("build", "Build"), ("plan", "Plan")], "build")]
        default: return []
        }
    }
}
