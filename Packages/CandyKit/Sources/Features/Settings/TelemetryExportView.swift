import AppKit
import DesignSystem
import T3Protocol

/// `TelemetryExportForm` (TelemetryExportSettings.tsx:58-243, 2994): the OTLP traces, metrics and logs endpoints
/// of one environment, each with its check status and Test button, then Discard and Save. The page keeps one
/// form per environment so drafts survive its refreshes. Saved endpoints are checked when the form opens.
@MainActor
final class TelemetryExportView: DSView, SettingsGroupRow {
    static let signals: [(key: String, label: String, signal: String)] = [
        ("otlpTracesUrl", "Traces", "traces"), ("otlpMetricsUrl", "Metrics", "metrics"), ("otlpLogsUrl", "Logs", "logs"),
    ]

    let environmentId: String
    private let context: SettingsPageContext
    private var environmentLabel = ""
    private var saved: [String: String] = [:]
    private var running: [String: String] = [:]
    private var canEdit = false
    private var drafts: [String: String] = [:]
    /// The latest check per field: the URL it checked and the result, nil while it runs.
    private var checks: [String: (url: String, result: OtlpEndpointCheckResult?)] = [:]
    private var saving = false
    private var message: String?
    private var started = false
    /// True while `apply` writes a field, whose change callback must not count as an edit.
    private var syncing = false

    private let intro = TextBlockView("Send traces, metrics, and logs to an OTLP HTTP receiver. Restart the server to apply. Environment variables override these settings.",
                                      font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    private let denied = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    private var fields: [Field] = []
    private let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let discard = ButtonView("Discard", variant: .outline, size: .xs)
    private let save = ButtonView("Save", variant: .default, size: .xs)

    init(context: SettingsPageContext, environmentId: String) {
        self.context = context
        self.environmentId = environmentId
        super.init(frame: .zero)
        status.lineHeight = 16
        status.truncates = true
        for v in [intro, denied, status, discard, save] as [NSView] { addSubview(v) }
        for s in Self.signals {
            let f = Field(label: "\(s.label) endpoint", placeholder: "http://localhost:4318/v1/\(s.signal)")
            f.input.onChange = { [weak self] text in
                guard let self, !self.syncing else { return }
                // Restoring the saved value drops the draft, so a later save can't resend it over another client's change.
                if text.trimmingCharacters(in: .whitespacesAndNewlines) == self.saved[s.key] { self.drafts[s.key] = nil } else { self.drafts[s.key] = text }
                self.message = nil
                self.apply()
            }
            f.input.onSubmit = { [weak self] in self?.submit() }
            f.test.action = { [weak self] in self?.check(s.key, s.signal, self?.value(s.key) ?? "") }
            fields.append(f)
            addSubview(f)
        }
        discard.action = { [weak self] in self?.discardDrafts() }
        save.action = { [weak self] in self?.submit() }
    }

    /// Reads the environment's saved and running endpoints. The first call checks the saved ones.
    func update(environment: SettingsScopeEnvironment, observability: JSONValue?) {
        environmentLabel = environment.label
        canEdit = environment.canWrite
        let o = environment.settings?["observability"]
        for s in Self.signals {
            saved[s.key] = o?[s.key]?.stringValue ?? ""
            running[s.key] = observability?[s.key]?.stringValue ?? ""
        }
        if !started {
            started = true
            for s in Self.signals where OtlpEndpointCheckResult.isHttpURL(saved[s.key] ?? "") { check(s.key, s.signal, saved[s.key] ?? "") }
        }
        apply()
    }

    private func value(_ key: String) -> String { (drafts[key] ?? saved[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: [String] { Self.signals.map(\.key).filter { value($0) != saved[$0] } }

    private func check(_ key: String, _ signal: String, _ url: String) {
        guard OtlpEndpointCheckResult.isHttpURL(url), canEdit, let request = context.request else { return }
        checks[key] = (url, nil)
        apply()
        let env = environmentId
        Task { @MainActor [weak self] in
            let result: OtlpEndpointCheckResult?
            do { result = OtlpEndpointCheckResult(json: try await request(env, "server.checkOtlpEndpoint", OtlpEndpointCheckResult.input(signal: signal, url: url))) }
            catch { result = nil }
            // A newer check for the same field replaces this one.
            guard let self, let current = self.checks[key], current.url == url, current.result == nil else { return }
            self.checks[key] = result.map { (url, $0) }
            self.apply()
        }
    }

    private func discardDrafts() {
        drafts = [:]
        message = nil
        // A tested draft replaced the saved endpoint's status; check the saved one again.
        for s in Self.signals where checks[s.key]?.url != saved[s.key] { check(s.key, s.signal, saved[s.key] ?? "") }
        apply()
    }

    private func submit() {
        let keys = changed
        guard !keys.isEmpty, !saving, canEdit, let request = context.request else { return }
        // `type="url"` with `pattern`: the browser refuses anything but empty or http(s).
        guard keys.allSatisfy({ value($0).isEmpty || OtlpEndpointCheckResult.isHttpURL(value($0)) }) else {
            message = "Enter an HTTP or HTTPS endpoint, or leave empty to disable export."
            apply()
            return
        }
        saving = true
        message = nil
        apply()
        let env = environmentId
        let patch: JSONValue = .object(["patch": .object(["observability": .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, JSONValue.string(value($0))) }))])])
        Task { @MainActor [weak self] in
            do {
                let result = try await request(env, "server.updateSettings", patch)
                self?.drafts = [:]
                self?.message = "Saved. Restart the server to apply."
                self?.context.applySettings?(env, result)
            } catch {
                self?.context.toast?("Setting not saved", "\(error)", .error)
            }
            self?.saving = false
            self?.apply()
        }
    }

    private func apply() {
        denied.text = "This connection lacks permission to change settings on \(environmentLabel.isEmpty ? "the selected environment" : environmentLabel)."
        denied.isHidden = canEdit
        for (i, s) in Self.signals.enumerated() {
            let f = fields[i]
            let url = value(s.key)
            let shown = drafts[s.key] ?? saved[s.key] ?? ""
            if f.input.text != shown, !f.input.state.focused || drafts[s.key] == nil {
                syncing = true
                f.input.text = shown
                syncing = false
            }
            f.input.isEnabled = !saving && canEdit
            let st = OtlpEndpointCheckResult.status(url: url, check: checks[s.key])
            f.status.text = st.label
            f.dot.tone = switch st.tone { case .off: .off; case .checking: .warning; case .success: .success; case .failure: .destructive }
            f.test.isEnabled = canEdit && OtlpEndpointCheckResult.isHttpURL(url) && !(checks[s.key].map { $0.result == nil } ?? false)
            let r = running[s.key] ?? ""
            f.running = saved[s.key] != r ? "Running: \(r.isEmpty ? "Disabled" : r)" : nil
        }
        status.text = message ?? ""
        let can = !changed.isEmpty && !saving && canEdit
        discard.isEnabled = can
        save.isEnabled = can
        save.title = saving ? "Saving…" : "Save"
        needsLayout = true
        (superview as? SettingsGroupView)?.needsLayout = true
        invalidateIntrinsicContentSize()
    }

    // MARK: Layout (`grid gap-4 px-4 py-4 sm:px-5`)

    private func blocks(_ width: CGFloat) -> [(NSView, CGFloat)] {
        let inner = max(0, width - 40)
        var out: [(NSView, CGFloat)] = [(intro, intro.height(forWidth: inner))]
        if !denied.isHidden { out.append((denied, denied.height(forWidth: inner))) }
        for f in fields { out.append((f, f.height(forWidth: inner))) }
        return out
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let b = blocks(width)
        return 16 + b.reduce(0) { $0 + $1.1 } + 16 * CGFloat(b.count) + 24 + 16
    }

    override func layout() {
        super.layout()
        let inner = max(0, bounds.width - 40)
        var y: CGFloat = 16
        for (v, h) in blocks(bounds.width) {
            v.frame = NSRect(x: 20, y: y, width: inner, height: h)
            y += h + 16
        }
        let sw = save.intrinsicContentSize.width, dw = discard.intrinsicContentSize.width
        save.frame = NSRect(x: 20 + inner - sw, y: y, width: sw, height: 24)
        discard.frame = NSRect(x: save.frame.minX - 8 - dw, y: y, width: dw, height: 24)
        status.frame = NSRect(x: 20, y: y + 4, width: max(0, discard.frame.minX - 12 - 20), height: 16)
    }

    /// One endpoint (`grid gap-1.5`): the dot, label and status line, the input with Test, and the running value.
    final class Field: DSView {
        let dot = StatusDotView()
        let label: LabelView
        let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        let input: InputView
        let test = ButtonView("Test", variant: .outline, size: .sm)
        private let runningText = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
        var running: String? { didSet { runningText.text = running ?? ""; runningText.isHidden = running == nil; needsLayout = true } }

        init(label text: String, placeholder: String) {
            label = LabelView(text, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
            input = InputView(placeholder: placeholder, text: "", size: .sm)
            super.init(frame: .zero)
            label.lineHeight = 16
            status.lineHeight = 16
            input.setAccessibilityLabel(text)
            test.setAccessibilityLabel("Test \(text)")
            runningText.isHidden = true
            for v in [dot, label, status, input, test, runningText] as [NSView] { addSubview(v) }
        }

        func height(forWidth width: CGFloat) -> CGFloat { 16 + 6 + 28 + (running == nil ? 0 : 6 + runningText.height(forWidth: width)) }

        override func layout() {
            super.layout()
            let w = bounds.width
            dot.frame = NSRect(x: 0, y: 2, width: 12, height: 12)
            label.frame = NSRect(x: 18, y: 0, width: ceil(label.textWidth) + 1, height: 16)
            let sw = ceil(status.textWidth) + 1
            status.frame = NSRect(x: w - sw, y: 0, width: sw, height: 16)
            let tw = test.intrinsicContentSize.width
            test.frame = NSRect(x: w - tw, y: 22, width: tw, height: 28)
            input.frame = NSRect(x: 0, y: 22, width: max(0, w - tw - 8), height: 28)
            runningText.frame = NSRect(x: 0, y: 56, width: w, height: runningText.height(forWidth: w))
        }
    }
}
