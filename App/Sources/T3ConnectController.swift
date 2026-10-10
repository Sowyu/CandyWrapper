import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// T3 Connect in the app: the account (Clerk session, relay, authorizer), the sign-in sheet, the account
/// menu and its "T3 Connect" page, and the account's machines for Settings > Connections. Machines added
/// from the account become catalog entries with a relay route, so `Environments` connects them like any
/// other environment and their threads join the sidebar.
@MainActor
final class T3ConnectController {
    private let environments: Environments
    private let fake: Bool
    private let identity = ClientIdentity(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    private(set) var account: T3ConnectAccount?
    private(set) var signedIn: ClerkAccount?
    private(set) var loaded = false
    /// The account's machines, nil before the first discovery.
    private(set) var machines: [T3ConnectMachine]?
    private(set) var discovering = false
    private(set) var discoveryError: String?
    private(set) var adding: Set<String> = []
    private var observers: [UUID: () -> Void] = [:]

    private var modal: ModalHost?
    private var flow: T3ConnectSignInFlow?
    private var accountPage: (page: T3ConnectAccountView, model: T3ConnectAccountModel)?

    /// Shows a toast on the open settings page.
    var toast: ((String, String?, ToastQueue.Kind) -> Void)?

    init(environments: Environments, fake: Bool) {
        self.environments = environments
        self.fake = fake
    }

    @discardableResult
    func observe(_ change: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = change
        return id
    }

    private func changed() { for o in observers.values { o() } }

    // MARK: Account

    /// Reads a stored session at launch. The DPoP key is created only once someone signs in, so a user
    /// who never does gets no Keychain item.
    func start() {
        if fake {
            account = try? FakeT3Connect.makeAccount(identity: identity)
            finishLoading()
            return
        }
        Task {
            let stored = await Task.detached { (try? ClerkKeychainStore().load())?.sessionId != nil }.value
            if stored { _ = await ensureAccount() }
            finishLoading()
        }
    }

    private func finishLoading() {
        Task {
            signedIn = await account?.account()
            loaded = true
            environments.t3Connect = account?.authorizer
            changed()
            if signedIn != nil { refreshMachines() }
        }
    }

    /// The account, created on first use. Keychain work runs off the main thread.
    private func ensureAccount() async -> T3ConnectAccount? {
        if let account { return account }
        let identity = self.identity
        do {
            let made = try await Task.detached { try T3ConnectAccount.production(identity: identity, device: .current) }.value
            account = made
            environments.t3Connect = made.authorizer
            return made
        } catch {
            NSLog("T3 Connect unavailable: %@", String(describing: error))
            return nil
        }
    }

    // MARK: Sign in

    func presentSignIn(in window: NSWindow) {
        guard modal == nil else { return }
        Task {
            guard let account = await ensureAccount() else {
                toast?("Could not start T3 Connect sign-in", "Couldn't create this device's T3 Connect key in the Keychain.", .error)
                return
            }
            showSignIn(account, in: window)
        }
    }

    private func showSignIn(_ account: T3ConnectAccount, in window: NSWindow) {
        guard modal == nil else { return }
        let (dialog, form) = T3ConnectSignInDialog.make()
        let flow = T3ConnectSignInFlow(clerk: account.clerk)
        self.flow = flow
        form.onHeightChange = { [weak dialog] in dialog?.superview?.needsLayout = true }
        form.onSubmitEmail = { [weak flow] email in Task { await flow?.submitEmail(email) } }
        form.onSubmitCode = { [weak flow] code in Task { await flow?.submitCode(code) } }
        form.onSubmitPassword = { [weak flow] password in Task { await flow?.submitPassword(password) } }
        form.onResend = { [weak flow] in Task { await flow?.resend() } }
        form.onEditEmail = { [weak flow] in flow?.editEmail() }
        form.onOtherMethod = { [weak flow] in
            guard let flow else { return }
            if flow.step == .password { Task { await flow.useEmailCode() } } else { flow.usePassword() }
        }
        flow.onChange = { [weak self, weak flow, weak form, weak window] in
            guard let self, let flow, let form else { return }
            let before = form.model.step
            let step: T3ConnectSignInModel.Step
            switch flow.step {
            case .email: step = .email
            case .code(let sentTo): step = .code(sentTo: sentTo)
            case .password: step = .password
            case .signedIn(let account):
                self.didSignIn(account)
                return
            }
            form.set(T3ConnectSignInModel(step: step, email: flow.email, busy: flow.isBusy, resending: flow.busy == .resending,
                                          error: flow.error, notice: flow.notice))
            if step != before { window?.makeFirstResponder(form.focusTarget) }
        }
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil; self?.flow = nil }
        modal = host
        window.makeFirstResponder(form.emailField)
    }

    private func didSignIn(_ clerkAccount: ClerkAccount) {
        modal?.close()
        signedIn = clerkAccount
        machines = nil
        changed()
        // ponytail: T3 opens "Set up T3 Connect" (publish this machine, connect devices) here; CandyWrapper
        // hosts no server to publish, so it goes straight to the account's machines
        refreshMachines()
    }

    // MARK: Account menu

    /// Clerk's `UserButton` menu: the signed-in address, the "T3 Connect" page, "Sign out".
    // ponytail: no menu icons (Clerk has a cog and a log-out glyph); add them with the icon set update
    func showAccountMenu(from trigger: NSView, window: NSWindow) {
        guard let signedIn else { return }
        let items: [MenuItem] = [
            .label(signedIn.identifier ?? "Signed in"),
            .separator,
            // The menu closes after its action returns; a modal opened inside the action would keep it up.
            MenuItem("T3 Connect", action: { [weak self, weak window] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        self?.presentAccountPage(in: window)
                    }
                }
            }),
            .separator,
            MenuItem("Sign out", action: { [weak self] in self?.signOut() }),
        ]
        MenuPopupView.show(items, from: trigger, placement: PopupPlacement(side: .top, align: .end, sideOffset: 4))
    }

    func signOut() {
        guard let account else { return }
        let catalog = environments.catalog
        Task {
            do {
                let result = try await account.signOut(catalog: catalog)
                await environments.appliedRelayRemoval(removed: result.removed, updated: result.updated)
            } catch {
                toast?("Could not sign out", "\(error)", .error)
            }
            signedIn = nil
            machines = nil
            discoveryError = nil
            changed()
        }
    }

    // MARK: Machines

    func refreshMachines() {
        guard let account, signedIn != nil, !discovering else { return }
        discovering = true
        changed()
        Task {
            do {
                machines = try await account.discover()
                discoveryError = nil
            } catch CloudSessionError.signedOut {
                signedIn = nil
                machines = nil
            } catch {
                discoveryError = T3Connect.failure(for: error).detail
            }
            discovering = false
            changed()
            refreshAccountPage()
        }
    }

    /// `Add` on a T3 Connect row: save the machine with a relay route and connect it.
    func add(_ environmentId: String) {
        guard let account, let machine = machines?.first(where: { $0.environmentId == environmentId }), !adding.contains(environmentId) else { return }
        let routeOnly = environments.saved.contains { $0.environmentId == environmentId }
        adding.insert(environmentId)
        changed()
        let catalog = environments.catalog
        Task {
            do {
                let saved = try await account.add(machine, to: catalog)
                environments.addedRelay(saved)
                if routeOnly {
                    toast?("T3 Connect route added", "\(machine.record.label) falls back to T3 Connect when its other routes are unreachable.", .success)
                } else {
                    toast?("Environment added", "Connecting to \(machine.record.label) through T3 Connect.", .success)
                }
            } catch {
                toast?("Could not connect environment", T3Connect.failure(for: error).detail, .error)
            }
            adding.remove(environmentId)
            changed()
        }
    }

    /// Rows for the machines not saved over T3 Connect (CloudEnvironmentConnectRows).
    func cloudModel(primaryId: String?) -> ConnectionsPageModel.Cloud {
        guard signedIn != nil else { return .idle }
        guard let machines else { return discoveryError.map { .failed($0) } ?? .loading }
        let saved = environments.saved
        let rows = machines.compactMap { m -> ConnectionsPageModel.CloudMachine? in
            let registration = saved.first { $0.environmentId == m.environmentId }
            if m.environmentId == primaryId || registration?.relay != nil { return nil }
            let notAdded = registration != nil ? "Saved without T3 Connect" : "Not added"
            let action: ConnectionsPageModel.CloudMachine.Action = adding.contains(m.environmentId) ? .adding
                : m.unsupportedReason.map { .unsupported($0) } ?? .add(registration != nil ? "Add route" : "Add")
            let (status, dot, tip, isError): (String, ConnectionsPageModel.CloudMachine.Dot, String, Bool) = switch m.availability {
            case .online: ("T3 Connect · \(notAdded) · Relay online", .success, "Relay online", false)
            case .offline: (m.offlineReason ?? "T3 Connect · \(notAdded) · Relay offline", .idle, m.offlineReason ?? "Relay offline", false)
            case .checking: ("T3 Connect · \(notAdded) · Checking relay status…", .warning, "Checking relay status", false)
            case .error(let message): (message, .destructive, message, true)
            }
            let unsupported = m.unsupportedReason.map { _ in "T3 Connect · \(notAdded) · Client not supported" }
            return ConnectionsPageModel.CloudMachine(
                id: m.environmentId, label: m.record.label, machine: m.machine ?? registration?.machine ?? "server",
                status: unsupported ?? status, statusIsError: unsupported == nil && isError, dot: dot,
                dotTooltip: m.unsupportedReason ?? tip, action: action)
        }
        if rows.isEmpty, let discoveryError { return .failed(discoveryError) }
        return .machines(rows)
    }

    // MARK: The account's "T3 Connect" page

    func presentAccountPage(in window: NSWindow) {
        guard modal == nil else { return }
        let (dialog, page) = T3ConnectAccountDialog.make()
        page.onHeightChange = { [weak dialog] in dialog?.superview?.needsLayout = true }
        page.onConfirm = { [weak self] id in self?.updateAccountPage { $0.confirming = id } }
        page.onDeregister = { [weak self] id in self?.deregister(id) }
        accountPage = (page, T3ConnectAccountModel())
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil; self?.accountPage = nil }
        modal = host
        refreshAccountPage()
        refreshMachines()
    }

    private func refreshAccountPage() {
        updateAccountPage { model in
            if let machines {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                model.content = .environments(machines.map { m in
                    let date = formatter.date(from: m.record.linkedAt) ?? ISO8601DateFormatter().date(from: m.record.linkedAt)
                    return .init(id: m.environmentId, label: m.record.label,
                                 detail: T3ConnectAccountModel.detail(linkedAt: date, providerKind: m.record.endpoint.providerKind))
                })
            } else if let discoveryError {
                model.content = .failed(discoveryError)
            } else {
                model.content = .loading
            }
        }
    }

    private func updateAccountPage(_ change: (inout T3ConnectAccountModel) -> Void) {
        guard var current = accountPage else { return }
        change(&current.model)
        accountPage = current
        current.page.set(current.model)
    }

    private func deregister(_ environmentId: String) {
        guard let account, accountPage?.model.deregistering == nil else { return }
        updateAccountPage { $0.deregistering = environmentId }
        Task {
            do {
                try await account.deregister(environmentId: environmentId)
                machines?.removeAll { $0.environmentId == environmentId }
                updateAccountPage { $0.deregistering = nil; $0.confirming = nil }
                refreshAccountPage()
                changed()
                toast?("Server deregistered", "T3 Connect access was revoked and a host space is now available.", .success)
                refreshMachines()
            } catch {
                updateAccountPage { $0.deregistering = nil }
                toast?("Could not deregister server", T3Connect.failure(for: error).detail, .error)
            }
        }
    }
}
