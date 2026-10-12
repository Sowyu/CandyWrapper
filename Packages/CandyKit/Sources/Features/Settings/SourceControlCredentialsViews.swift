import AppKit
import DesignSystem
import T3Protocol

// MARK: Logic (GitHubAccountSettings.logic.ts, BitbucketCredentialsSettings.tsx:40-112)

/// One login `gh` holds, from `auth.accounts` of the GitHub discovery item (contracts sourceControl.ts).
public struct GitHubDiscoveredAccount: Equatable, Sendable {
    public var host: String
    public var account: String
    public var active: Bool
    public var authenticated: Bool
    public var environmentVariable: String?
    public var error: String?

    public init(host: String, account: String, active: Bool = false, authenticated: Bool = true,
                environmentVariable: String? = nil, error: String? = nil) {
        self.host = host; self.account = account; self.active = active; self.authenticated = authenticated
        self.environmentVariable = environmentVariable; self.error = error
    }

    public init?(_ json: JSONValue) {
        guard let host = json["host"]?.stringValue, let account = json["account"]?.stringValue else { return nil }
        self.init(host: host, account: account, active: json["active"]?.boolValue ?? false,
                  authenticated: json["authenticated"]?.boolValue ?? false,
                  environmentVariable: optionValue(json["environmentVariable"])?.stringValue,
                  error: optionValue(json["error"])?.stringValue)
    }
}

/// `GitHubHostGroup`: gh's logins for one host.
public struct GitHubHostGroup: Equatable, Sendable {
    public var host: String
    /// gh's active stored login, used when Settings pin nothing.
    public var activeAccount: String?
    /// Stored logins that work and can be pinned.
    public var selectable: [String]
    /// Logins gh holds but cannot use.
    public var broken: [GitHubDiscoveredAccount]
    /// Set when GH_TOKEN or a sibling overrides every stored login for this host.
    public var environmentVariable: String?
}

public enum GitHubAccountsLogic {
    /// `groupGitHubAccounts`: by host, in the order gh reported the hosts.
    public static func group(_ accounts: [GitHubDiscoveredAccount]) -> [GitHubHostGroup] {
        var hosts: [String] = []
        for a in accounts where !hosts.contains(a.host) { hosts.append(a.host) }
        return hosts.map { host in
            let entries = accounts.filter { $0.host == host }
            let stored = entries.filter { $0.environmentVariable == nil }
            let selectable = stored.filter(\.authenticated)
            return GitHubHostGroup(host: host, activeAccount: (selectable.first(where: \.active) ?? selectable.first)?.account,
                                   selectable: selectable.map(\.account), broken: stored.filter { !$0.authenticated },
                                   environmentVariable: entries.first(where: { !($0.environmentVariable ?? "").isEmpty })?.environmentVariable)
        }
    }

    /// `nextGitHubHosts`: the whole `hosts` map after one host changes. `account: .some(nil)` unpins.
    /// Hosts back on gh's defaults (enabled, nothing pinned) are dropped.
    public static func nextHosts(_ current: [String: JSONValue], host: String, enabled: Bool? = nil,
                                 account: String?? = .none) -> [String: JSONValue] {
        let previous = current[host]
        let on = enabled ?? previous?["enabled"]?.boolValue ?? true
        let pinned: String? = switch account { case .none: previous?["account"]?.stringValue; case .some(let a): a }
        var next = current
        next.removeValue(forKey: host)
        if on && pinned == nil { return next }
        var entry: [String: JSONValue] = ["enabled": .bool(on)]
        if let pinned { entry["account"] = .string(pinned) }
        next[host] = .object(entry)
        return next
    }
}

public enum BitbucketCredentialsLogic {
    public enum Method: Int, Sendable { case accessToken = 0, apiToken = 1 }

    public struct Saved: Equatable, Sendable {
        public var accessToken = "", email = "", apiToken = ""
        public init(accessToken: String = "", email: String = "", apiToken: String = "") {
            self.accessToken = accessToken; self.email = email; self.apiToken = apiToken
        }
        public init(_ json: JSONValue?) {
            self.init(accessToken: json?["accessToken"]?.stringValue ?? "", email: json?["email"]?.stringValue ?? "",
                      apiToken: json?["apiToken"]?.stringValue ?? "")
        }
        /// `savedMethod`.
        public var method: Method? {
            if !accessToken.isEmpty { return .accessToken }
            if !email.isEmpty && !apiToken.isEmpty { return .apiToken }
            return nil
        }
        var json: JSONValue { .object(["accessToken": .string(accessToken), "email": .string(email), "apiToken": .string(apiToken)]) }
    }

    /// The patch Save sends, or nil when Save is off. Saving one method clears the other; resending the
    /// saved token's redacted value keeps it.
    public static func patch(method: Method, saved: Saved, accessToken: String, email emailDraft: String?, apiToken: String) -> Saved? {
        let newAccess = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let newApi = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (emailDraft ?? saved.email).trimmingCharacters(in: .whitespacesAndNewlines)
        let patch: Saved?
        switch method {
        case .accessToken: patch = newAccess.isEmpty ? nil : Saved(accessToken: newAccess)
        case .apiToken:
            patch = !email.isEmpty && !(newApi.isEmpty && saved.apiToken.isEmpty)
                ? Saved(email: email, apiToken: newApi.isEmpty ? saved.apiToken : newApi) : nil
        }
        guard let patch else { return nil }
        let methodIsSaved = saved.method == method
        return method == .accessToken || !methodIsSaved || !newApi.isEmpty || email != saved.email ? patch : nil
    }
}

// MARK: Bitbucket (BitbucketCredentialsSettings.tsx)

/// An access token, or an Atlassian email plus API token, never both. Tokens are write-only: the server
/// reports only whether each is set.
final class BitbucketCredentialsView: DSView, SettingsGroupRow {
    private struct Info { let label, description, link, linkLabel: String }
    private static let methods: [Info] = [
        Info(label: "Access token", description: "Scoped to one repository, project, or workspace. Create it in that item's Bitbucket settings.",
             link: "https://support.atlassian.com/bitbucket-cloud/docs/access-tokens/", linkLabel: "Learn more"),
        Info(label: "API token", description: "Uses your Atlassian account, so it reaches every repository you can. Give it read and write access to repositories and pull requests, and read:user:bitbucket.",
             link: "https://id.atlassian.com/manage-profile/security/api-tokens", linkLabel: "Create an API token"),
    ]

    private let methodGroup = ToggleGroupView(variant: .segmented, items: methods.map { ($0.label, nil) }, selected: 0)
    private let info = TextBlockView()
    private let link = CredentialsInlineLink()
    private let firstLabel = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let tokenLabel = LabelView("API token", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    let accessToken = SecureInputView(placeholder: "Not set")
    let email = InputView(placeholder: "you@example.com", text: "", size: .sm)
    let apiToken = SecureInputView(placeholder: "Not set")
    private let note = TextBlockView()
    let remove = ButtonView("Remove", variant: .outline, size: .xs)
    let save = ButtonView("Save", size: .xs)
    private let context: SettingsPageContext
    private let environmentId: String
    private let onSaved: () -> Void
    var methodChoice: BitbucketCredentialsLogic.Method? { didSet { sync() } }
    private var emailDraft: String?
    private var saving = false { didSet { sync() } }
    /// Set while `sync` writes the email field, so its change callback does not echo back.
    private var syncing = false

    init(context: SettingsPageContext, environmentId: String, onSaved: @escaping () -> Void) {
        self.context = context
        self.environmentId = environmentId
        self.onSaved = onSaved
        super.init(frame: .zero)
        methodGroup.setAccessibilityLabel("Bitbucket sign-in method")
        methodGroup.onChange = { [weak self] index in
            guard let self else { return }
            if let index { self.methodChoice = BitbucketCredentialsLogic.Method(rawValue: index) }
            self.sync()
        }
        for t in [info, note] {
            t.font = DSFont.ui(12)
            t.color = Themed.color(\.mutedForeground)
        }
        info.lineHeight = 19.5
        note.lineHeight = 16
        link.action = { [weak self] in
            guard let self, let url = URL(string: Self.methods[self.method.rawValue].link) else { return }
            self.context.openURL?(url)
        }
        firstLabel.lineHeight = 16
        tokenLabel.lineHeight = 16
        email.setAccessibilityLabel("Atlassian account email")
        accessToken.setAccessibilityLabel("Access token")
        for f in [accessToken, apiToken] { f.inset = 9 }
        apiToken.setAccessibilityLabel("API token")
        accessToken.onChange = { [weak self] _ in self?.sync() }
        apiToken.onChange = { [weak self] _ in self?.sync() }
        email.onChange = { [weak self] text in guard let self, !self.syncing else { return }; self.emailDraft = text; self.sync() }
        for f in [accessToken, apiToken] { f.onSubmit = { [weak self] in self?.submit() } }
        email.onCommit = { [weak self] _ in self?.submit() }
        save.action = { [weak self] in self?.submit() }
        remove.action = { [weak self] in self?.write(BitbucketCredentialsLogic.Saved()) }
        for v in [methodGroup, info, link, firstLabel, tokenLabel, accessToken, email, apiToken, note, remove, save] as [NSView] { addSubview(v) }
        sync()
    }

    private var saved: BitbucketCredentialsLogic.Saved { .init(context.configs[environmentId]?.settings.sourceControlHost("bitbucket")) }
    private var method: BitbucketCredentialsLogic.Method { methodChoice ?? saved.method ?? .accessToken }
    private var patch: BitbucketCredentialsLogic.Saved? {
        BitbucketCredentialsLogic.patch(method: method, saved: saved, accessToken: accessToken.text, email: emailDraft, apiToken: apiToken.text)
    }

    private func sync() {
        let saved = saved, method = method
        let current = saved.method, methodIsSaved = current == method
        methodGroup.selectedIndex = method.rawValue
        let i = Self.methods[method.rawValue]
        info.text = i.description
        link.title = i.linkLabel
        firstLabel.text = method == .accessToken ? "Access token" : "Atlassian account email"
        let placeholder = methodIsSaved ? "Stored secret, enter a new value to replace" : "Not set"
        accessToken.placeholder = placeholder
        apiToken.placeholder = placeholder
        accessToken.isHidden = method != .accessToken
        email.isHidden = method != .apiToken
        apiToken.isHidden = method != .apiToken
        tokenLabel.isHidden = method != .apiToken
        if !email.state.focused, email.text != (emailDraft ?? saved.email) { syncing = true; email.text = emailDraft ?? saved.email; syncing = false }
        note.text = current == nil ? "Without a saved token, the server falls back to its T3CODE_BITBUCKET_* environment variables."
            : methodIsSaved ? "" : "Saving replaces your \(Self.methods[current!.rawValue].label.lowercased())."
        remove.isHidden = current == nil
        remove.isEnabled = !saving
        save.isEnabled = patch != nil && !saving
        for c in [accessToken, apiToken] { c.isEnabled = !saving }
        email.isEnabled = !saving
        methodGroup.items.forEach { $0.isEnabled = !saving }
        link.isEnabled = !saving
        needsLayout = true
    }

    private func submit() { if let patch, !saving { write(patch) } }

    /// `server.updateSettings` with Bitbucket's fields (`bitbucket` or `sourceControlHosts.bitbucket`) on this environment only.
    private func write(_ next: BitbucketCredentialsLogic.Saved) {
        guard let request = context.request, !saving, let settings = context.configs[environmentId]?.settings else { return }
        saving = true
        let env = environmentId
        let patch = settings.sourceControlHostPatch("bitbucket", next.json.objectValue ?? [:])
        Task { [weak self] in
            do {
                let result = try await request(env, "server.updateSettings", .object(["patch": patch]))
                self?.context.applySettings?(env, result)
                self?.accessToken.text = ""
                self?.apiToken.text = ""
                self?.emailDraft = nil
                self?.onSaved()
            } catch {
                self?.context.toast?("Setting not saved", "\(error)", .error)
            }
            self?.saving = false
        }
    }

    /// The paragraph and where the inline link goes: after its last line when it fits (`{description}{" "}<InlineButton>`),
    /// else on a line of its own.
    private func paragraph(_ w: CGFloat) -> (height: CGFloat, link: NSPoint) {
        let l = info.layout(forWidth: w)
        let lw = link.intrinsicContentSize.width, space = (" " as NSString).size(withAttributes: [.font: DSFont.ui(12)]).width
        let last = l.widths.last ?? 0
        if last + space + lw <= w { return (l.height, NSPoint(x: last + space, y: l.height - l.lineHeight)) }
        return (l.height + l.lineHeight, NSPoint(x: 0, y: l.height))
    }

    private var footerHeight: CGFloat { 24 }
    private var fieldsHeight: CGFloat { method == .accessToken ? 22 + 28 : (22 + 28) + 16 + (22 + 28) }

    func height(forWidth width: CGFloat) -> CGFloat {
        methodGroup.intrinsicContentSize.height + 16 + paragraph(width).height + 16 + fieldsHeight + 16
            + max(footerHeight, note.height(forWidth: noteWidth(width)))
    }

    private func noteWidth(_ w: CGFloat) -> CGFloat {
        max(0, w - save.intrinsicContentSize.width - 12 - (remove.isHidden ? 0 : remove.intrinsicContentSize.width + 8))
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let gs = methodGroup.intrinsicContentSize
        methodGroup.frame = NSRect(x: 0, y: 0, width: gs.width, height: gs.height)
        var y = gs.height + 16
        let p = paragraph(w)
        info.frame = NSRect(x: 0, y: y, width: w, height: info.height(forWidth: w))
        let ls = link.intrinsicContentSize
        link.frame = NSRect(x: p.link.x, y: y + p.link.y + (19.5 - ls.height) / 2, width: ls.width, height: ls.height)
        y += p.height + 16
        firstLabel.frame = NSRect(x: 0, y: y, width: w, height: 16)
        y += 22
        if method == .accessToken {
            accessToken.frame = NSRect(x: 0, y: y, width: w, height: 28)
        } else {
            email.frame = NSRect(x: 0, y: y, width: w, height: 28)
            y += 28 + 16
            tokenLabel.frame = NSRect(x: 0, y: y, width: w, height: 16)
            y += 22
            apiToken.frame = NSRect(x: 0, y: y, width: w, height: 28)
        }
        y += 28 + 16
        let nw = noteWidth(w), nh = note.height(forWidth: nw), rowH = max(footerHeight, nh)
        let sw = save.intrinsicContentSize.width
        save.frame = NSRect(x: w - sw, y: y + (rowH - 24) / 2, width: sw, height: 24)
        if !remove.isHidden {
            let rw = remove.intrinsicContentSize.width
            remove.frame = NSRect(x: w - sw - 8 - rw, y: y + (rowH - 24) / 2, width: rw, height: 24)
        }
        note.frame = NSRect(x: 0, y: y + (rowH - nh) / 2, width: nw, height: nh)
    }
}

// MARK: GitHub (GitHubAccountSettings.tsx)

/// Per-host GitHub choices: turn a host off, or pin which `gh` login it uses. Changes save at once.
final class GitHubAccountsView: DSView, SettingsGroupRow {
    private static let active = "Active gh account"
    private let context: SettingsPageContext
    private let environmentId: String
    private let onSaved: () -> Void
    private let groups: [GitHubHostGroup]
    private let intro = TextBlockView()
    private let reveal = ButtonView(nil, icon: .eye, variant: .ghostMuted, size: .iconXs)
    private var hostViews: [HostView] = []
    private var revealed = false
    private var saving = false { didSet { sync() } }

    init(context: SettingsPageContext, environmentId: String, accounts: [GitHubDiscoveredAccount], onSaved: @escaping () -> Void) {
        self.context = context
        self.environmentId = environmentId
        self.onSaved = onSaved
        groups = GitHubAccountsLogic.group(accounts)
        super.init(frame: .zero)
        intro.font = DSFont.ui(12)
        intro.lineHeight = 19.5
        intro.color = Themed.color(\.mutedForeground)
        intro.text = groups.isEmpty ? "Sign in with gh auth login on the server host, then rescan to choose accounts here."
            : "Choose which gh login each GitHub host uses, or turn a host off."
        addSubview(intro)
        guard !groups.isEmpty else { return }
        reveal.action = { [weak self] in guard let self else { return }; self.revealed.toggle(); self.sync() }
        addSubview(reveal)
        hostViews = groups.map { group in
            let v = HostView(group)
            v.toggle.onChange = { [weak self] on in self?.write(group.host, enabled: on) }
            v.select.onChange = { [weak self] i in self?.write(group.host, account: .some(i == 0 ? nil : group.selectable[i - 1])) }
            v.useActive.action = { [weak self] in self?.write(group.host, account: .some(nil)) }
            addSubview(v)
            return v
        }
        sync()
    }

    private var hosts: [String: JSONValue] { context.configs[environmentId]?.settings.sourceControlHost("github")?["hosts"]?.objectValue ?? [:] }

    private func shown(_ login: String) -> String { revealed ? login : UsageRedactedTextView.placeholder(login) }

    private func sync() {
        reveal.icon = revealed ? .eyeOff : .eye
        reveal.setAccessibilityLabel(revealed ? "Hide GitHub accounts" : "Reveal GitHub accounts")
        let hosts = hosts
        for v in hostViews {
            let g = v.group
            let choice = hosts[g.host]
            let enabled = choice?["enabled"]?.boolValue ?? true
            let pin = choice?["account"]?.stringValue
            let stale = pin != nil && !g.selectable.contains(pin!)
            v.toggle.isOn = enabled
            v.toggle.isEnabled = !saving
            v.signedIn.text = g.selectable.count == 1 ? "Signed in as \(shown(g.selectable[0]))" : ""
            let activeLabel = Self.active + (g.activeAccount.map { " (\(shown($0)))" } ?? "")
            v.select.options = [activeLabel] + g.selectable.map(shown)
            v.select.selectedIndex = pin.flatMap { p in stale ? nil : g.selectable.firstIndex(of: p).map { $0 + 1 } } ?? 0
            v.select.isEnabled = !saving && enabled
            v.stale = stale
            v.useActive.isEnabled = !saving
            v.brokenLines = g.broken.map { "\(shown($0.account)) can't be used: \($0.error ?? "gh reports this login as invalid.")" }
            v.environmentVariable = g.environmentVariable
            v.update()
        }
        needsLayout = true
    }

    /// `server.updateSettings` with GitHub's whole hosts map (`github` or `sourceControlHosts.github`).
    private func write(_ host: String, enabled: Bool? = nil, account: String?? = .none) {
        guard let request = context.request, !saving, let settings = context.configs[environmentId]?.settings else { return }
        saving = true
        let env = environmentId
        let next = GitHubAccountsLogic.nextHosts(hosts, host: host, enabled: enabled, account: account)
        let patch = settings.sourceControlHostPatch("github", ["hosts": .object(next)])
        Task { [weak self] in
            do {
                let result = try await request(env, "server.updateSettings", .object(["patch": patch]))
                self?.context.applySettings?(env, result)
                self?.onSaved()
            } catch {
                self?.context.toast?("Setting not saved", "\(error)", .error)
            }
            self?.saving = false
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let introH = max(24, intro.height(forWidth: width - (groups.isEmpty ? 0 : 36)))
        return hostViews.reduce(introH) { $0 + 16 + $1.height(forWidth: width) }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let iw = w - (groups.isEmpty ? 0 : 36)
        let ih = max(24, intro.height(forWidth: iw))
        intro.frame = NSRect(x: 0, y: (ih - intro.height(forWidth: iw)) / 2, width: iw, height: intro.height(forWidth: iw))
        reveal.frame = NSRect(x: w - 24, y: (ih - 24) / 2, width: 24, height: 24)
        var y = ih
        for v in hostViews {
            y += 16
            let h = v.height(forWidth: w)
            v.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h
        }
    }

    /// One host: name, "Signed in as", the switch, the account select, the stale pin warning, broken logins
    /// and the environment variable warning (`grid gap-2`).
    final class HostView: DSView {
        let group: GitHubHostGroup
        private let name = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
        let signedIn = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        let toggle = SwitchView()
        private let accountLabel = LabelView("Account", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        let select = SelectView(options: [], size: .sm)
        private let staleText = TextBlockView()
        let useActive = ButtonView("Use active login", variant: .outline, size: .xs)
        private var brokenViews: [TextBlockView] = []
        private let envText = TextBlockView()
        var stale = false
        var brokenLines: [String] = []
        var environmentVariable: String?

        init(_ group: GitHubHostGroup) {
            self.group = group
            super.init(frame: .zero)
            name.text = group.host
            name.lineHeight = 16
            signedIn.lineHeight = 16
            toggle.setAccessibilityLabel("Use GitHub on \(group.host)")
            select.setAccessibilityLabel("GitHub account for \(group.host)")
            select.popupAlign = .end
            select.alignItemWithTrigger = false
            accountLabel.lineHeight = 16
            for t in [staleText, envText] {
                t.font = DSFont.ui(12)
                t.lineHeight = 16
                t.color = Themed.color(\.warning)
            }
            staleText.text = "The chosen login is no longer signed in, so the active gh login is used."
            for v in [name, signedIn, toggle, accountLabel, select, staleText, useActive, envText] as [NSView] { addSubview(v) }
        }

        func update() {
            brokenViews.forEach { $0.removeFromSuperview() }
            brokenViews = brokenLines.map { line in
                let t = TextBlockView()
                t.font = DSFont.ui(12)
                t.lineHeight = 16
                t.color = Themed.color(\.mutedForeground, 0.7)
                t.text = line
                addSubview(t)
                return t
            }
            envText.text = environmentVariable.map { "\($0) is set on the server, so it overrides the account chosen here until it is unset." } ?? ""
            signedIn.isHidden = signedIn.text.isEmpty
            let many = group.selectable.count > 1
            accountLabel.isHidden = !many
            select.isHidden = !many
            staleText.isHidden = !stale
            useActive.isHidden = !stale
            envText.isHidden = environmentVariable == nil
            needsLayout = true
        }

        private var headH: CGFloat { signedIn.isHidden ? 24 : 36 }

        func height(forWidth w: CGFloat) -> CGFloat {
            var h = headH
            if !select.isHidden { h += 8 + 32 }
            if stale { h += 8 + max(24, staleText.height(forWidth: w - 140)) }
            for b in brokenViews { h += 8 + b.height(forWidth: w) }
            if environmentVariable != nil { h += 8 + envText.height(forWidth: w) }
            return h
        }

        override func layout() {
            super.layout()
            let w = bounds.width
            let ts = toggle.intrinsicContentSize
            toggle.frame = NSRect(x: w - ts.width, y: (headH - ts.height) / 2, width: ts.width, height: ts.height)
            name.frame = NSRect(x: 0, y: signedIn.isHidden ? 4 : 0, width: w - ts.width - 12, height: 16)
            signedIn.frame = NSRect(x: 0, y: 18, width: w - ts.width - 12, height: 16)
            var y = headH
            if !select.isHidden {
                y += 8
                let sw = min(256, w)
                select.frame = NSRect(x: w - sw, y: y, width: sw, height: 32)
                accountLabel.frame = NSRect(x: 0, y: y + 8, width: w - sw - 12, height: 16)
                y += 32
            }
            if stale {
                y += 8
                let bw = useActive.intrinsicContentSize.width
                let th = staleText.height(forWidth: w - bw - 12)
                let rowH = max(24, th)
                useActive.frame = NSRect(x: w - bw, y: y + (rowH - 24) / 2, width: bw, height: 24)
                staleText.frame = NSRect(x: 0, y: y + (rowH - th) / 2, width: w - bw - 12, height: th)
                y += rowH
            }
            for b in brokenViews {
                y += 8
                let h = b.height(forWidth: w)
                b.frame = NSRect(x: 0, y: y, width: w, height: h)
                y += h
            }
            if environmentVariable != nil {
                y += 8
                envText.frame = NSRect(x: 0, y: y, width: w, height: envText.height(forWidth: w))
            }
        }
    }
}

/// The GitHub row's details: the token form, then the accounts when `gh` is available (`grid gap-6`).
final class GitHubDetailsView: DSView, SettingsGroupRow {
    let token: GitHubTokenView
    let accounts: GitHubAccountsView?

    init(token: GitHubTokenView, accounts: GitHubAccountsView?) {
        self.token = token
        self.accounts = accounts
        super.init(frame: .zero)
        addSubview(token)
        accounts.map(addSubview)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        token.height(forWidth: width) + (accounts.map { 24 + $0.height(forWidth: width) } ?? 0)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, th = token.height(forWidth: w)
        token.frame = NSRect(x: 0, y: 0, width: w, height: th)
        accounts?.frame = NSRect(x: 0, y: th + 24, width: w, height: accounts!.height(forWidth: w))
    }
}

/// `InlineButton` with a trailing external-link glyph (`gap-0.5`, `size-3`): text-xs, medium, foreground.
// ponytail: no hover underline (LabelView has none); add it if the link needs a hover cue
final class CredentialsInlineLink: ControlView {
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let glyph = IconView(name: .externalLink, size: 12, strokeColor: Themed.color(\.foreground))
    var title: String = "" { didSet { label.text = title; setAccessibilityLabel(title); invalidateIntrinsicContentSize(); needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scalesWhenPressed = false
        label.lineHeight = 16
        addSubview(label)
        addSubview(glyph)
        setAccessibilityRole(.link)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1 + 2 + 12, height: 16) }
    override func layout() {
        super.layout()
        let lw = ceil(label.textWidth) + 1
        label.frame = NSRect(x: 0, y: 0, width: lw, height: 16)
        glyph.frame = NSRect(x: lw + 2, y: 2, width: 12, height: 12)
    }
}
