import AppKit
import DesignSystem
import T3Protocol

/// CandyWrapper-only (docs/decisions.md, 2026-11-20): "Unrestricted" access for Claude Code. On the wire it is Full
/// access plus `CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS=1` in the Claude provider instance's environment
/// (`providerInstances.<id>.environment`), the same list Settings > Providers edits. T3 has no such mode, and the
/// variable lives on the instance, so it covers every Full access thread of that instance on that machine.
///
/// Claude Code 2.1.328 reads the variable as a boolean (`1`, `true`, `yes` or `on`) and acts on it only in bypass
/// permissions mode, which T3 starts for Full access. T3 rebuilds the instance when its config changes, so a change
/// takes effect from each thread's next Claude session.
public enum UnrestrictedAccess {
    public static let variable = "CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS"
    /// The earliest Claude Code checked to read the variable. Its changelog never names it, so older builds may
    /// read it too; the hint warns rather than blocks.
    // ponytail: the only build on hand, lower it when an older release is confirmed to read the variable
    public static let minimumVersion = [2, 1, 328]
    public static let label = "Unrestricted"
    public static let description = "Full access, and Claude Code deletes files without asking. CandyWrapper approves the safety checks it still stops on before commands while connected. Applies to every Full access Claude thread on this machine."

    /// What the access menu shows for the open thread's provider instance; nil hides the entry.
    public struct State: Equatable, Sendable {
        public var on: Bool
        /// Set when the instance's Claude Code is older than any build checked to read the variable.
        public var unsupportedHint: String?
        public init(on: Bool, unsupportedHint: String? = nil) { self.on = on; self.unsupportedHint = unsupportedHint }
    }

    /// Whether the instance's environment turns it on: the variable with a value Claude Code reads as true, or a
    /// sensitive value the server hides (Claude Code still gets it).
    public static func isOn(_ instance: JSONValue) -> Bool {
        ProviderEnvironmentLogic.variables(instance).contains { v in
            guard v.name == variable else { return false }
            if v.valueRedacted == true { return true }
            return ["1", "true", "yes", "on"].contains(v.value.lowercased().trimmingCharacters(in: .whitespaces))
        }
    }

    /// The instance with the variable set to `1`, or with every copy of it removed.
    public static func instance(_ instance: JSONValue, on: Bool) -> JSONValue {
        var env = ProviderEnvironmentLogic.variables(instance).filter { $0.name != variable }
        if on { env.append(.init(name: variable, value: "1", sensitive: false)) }
        return ProviderEnvironmentLogic.instance(instance, environment: env)
    }

    /// The configured instance, or the default slot's implicit `{driver}` (ProvidersLogic.rows).
    public static func configured(_ settings: JSONValue, instanceId: String, driver: String) -> JSONValue {
        settings["providerInstances"]?[instanceId] ?? .object(["driver": .string(driver)])
    }

    /// The `server.updateSettings` payload: an upsert of the instance with the variable on or off.
    public static func payload(_ settings: JSONValue, instanceId: String, driver: String, on: Bool) -> JSONValue {
        .object(["patch": .object([:]), "providerInstanceMutation": .object([
            "operation": .string("upsert"), "instanceId": .string(instanceId),
            "instance": instance(configured(settings, instanceId: instanceId, driver: driver), on: on),
        ])])
    }

    /// Offered only for a Claude instance, on a server whose settings carry `providerInstances` (so it applies
    /// instance environments), to a client allowed to manage providers.
    public static func state(settings: JSONValue, instanceId: String?, driver: String?, version: String?, canManage: Bool) -> State? {
        guard driver == "claudeAgent", let instanceId, canManage, settings["providerInstances"]?.objectValue != nil else { return nil }
        let on = isOn(configured(settings, instanceId: instanceId, driver: "claudeAgent"))
        let hint = predates(version).map {
            "Checked with Claude Code \(minimumVersion.map(String.init).joined(separator: ".")). This machine has \($0), which may ignore it."
        }
        return State(on: on, unsupportedHint: hint)
    }

    /// The reported version when it parses and is older than `minimumVersion`.
    static func predates(_ version: String?) -> String? {
        guard let version, let match = version.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/) else { return nil }
        let parts = [Int(match.1) ?? 0, Int(match.2) ?? 0, Int(match.3) ?? 0]
        return parts.lexicographicallyPrecedes(minimumVersion) ? String(match.0) : nil
    }

    // MARK: Confirm once per instance

    /// Since 2026-11-26 the dialog also covers CandyWrapper approving Claude Code's safety checks
    /// (`UnrestrictedAutoApprove`). The key changed with it, so whoever confirmed the old `unrestrictedAccessConfirmed`
    /// sees the dialog once more, and CandyWrapper approves nothing for an instance until they do.
    static let confirmedKey = "unrestrictedAccessConfirmedWithApprovals"

    public static func needsConfirm(environment: String, instance: String, defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: confirmedKey) ?? []).contains("\(environment)|\(instance)")
    }

    public static func markConfirmed(environment: String, instance: String, defaults: UserDefaults = .standard) {
        let list = defaults.stringArray(forKey: confirmedKey) ?? []
        let key = "\(environment)|\(instance)"
        if !list.contains(key) { defaults.set(list + [key], forKey: confirmedKey) }
    }

    public static let dialogTitle = "Turn on Unrestricted for Claude?"
    public static func dialogMessage(machine: String, provider: String) -> String {
        "Claude Code skips its last permission prompts, the ones before risky rm commands. While a CandyWrapper window is connected to \(machine), CandyWrapper also approves the safety checks Claude Code still stops on before a command, such as one it couldn't read. This applies to every Full access thread that uses \(provider) on \(machine), not only this one.\n\nClaude Code will delete files and run those commands without asking anyone. Anthropic recommends this only for throwaway containers.\n\nClaude Code skips its prompts from each thread's next Claude session, and CandyWrapper's approvals start at once. Changing it restarts this machine's Claude sessions, so a running turn may stop."
    }
    /// The Settings switch's line while the instance is on but this dialog was never confirmed here.
    public static let unconfirmedHint = "CandyWrapper won't approve safety checks for this instance until you confirm: turn it off, then on."
    public static let confirmTitle = "Turn on Unrestricted"

    /// Runs `action` at once when this instance was confirmed before, else after the alert's destructive button.
    /// Cancel comes first, so it takes the initial focus and Return; Escape cancels too.
    @MainActor
    public static func confirm(in window: NSWindow?, environment: String, instance: String, machine: String, provider: String,
                               defaults: UserDefaults = .standard, then action: @escaping @MainActor () -> Void) {
        guard needsConfirm(environment: environment, instance: instance, defaults: defaults) else { return action() }
        guard let window else { return }
        let dialog = DialogView(kind: .alertDialog, title: dialogTitle, message: dialogMessage(machine: machine, provider: provider))
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView(confirmTitle, variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak host] in
            host?.close()
            markConfirmed(environment: environment, instance: instance, defaults: defaults)
            action()
        }
    }
}
