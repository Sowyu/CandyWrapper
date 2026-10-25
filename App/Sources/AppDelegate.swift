import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var galleryWindow: NSWindow?
    private var environments: Environments?
    private var server: ServerController?
    private var threads: ThreadController?
    private var ditherTabs: DitherTabsController?
    private var settings: SettingsController?
    private var sidebarCommands: SidebarCommands?
    private var t3Connect: T3ConnectController?
    private var shortcuts: Shortcuts?
    private var palette: PaletteCommands?
    private var menuBar: MenuBarController?
    private var routeHistory: RouteHistory?
    private var terminationSignal: DispatchSourceSignal?
    private var notifications: ThreadNotificationCoordinator?
    private var quitHold: QuitHoldController?
    private var slowRPCObserver: NSObjectProtocol?
    private var slowRPCToast: Int?
    private weak var slowRPCViewport: ToastViewport?
    private var providerUpdateToast: ProviderUpdateLaunchToast?
    private var welcomeOnboarding: WelcomeOnboardingController?
    private var snapShots: SnapShotController?
    private var openIn: OpenInController?
    private var orchestrator: OrchestratorController?
    private var connectors: ConnectorsController?
    /// The Orchestrator's "while closed" schedule was handed to T3 for this quit.
    private var orchestratorHandedOff = false
    /// Built on the first Cmd+Q hold.
    private var quitOverlay: QuitHoldOverlayView?
    /// The spec's performance HUD, toggled by the hidden menu item below or the palette.
    private lazy var performanceHUD = PerformanceHUD(events: PerfCounters.takeEvents, setCounting: PerfCounters.setCounting)
    private var desktopManaged: DesktopManagedController?
    private var updates: UpdateUI?
    private var updateEverything: UpdateEverything?
    private var updater: UpdateController?
    private var runtimeUpdater: RuntimeUpdateController?
    private let codexAuth = CodexAuthCallbackReceiver()
    private var chatGptWelcome: ChatGptWelcomeCoordinator?
    /// URLs that arrived before the window existed (a cold launch from a link).
    private var pendingURLs: [URL]? = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstance() { return }
        StallMonitor.start()
        if !CommandLine.arguments.contains("--server") { ServerController.prefetchCachedSidebar() }
        // The View menu carries its own Toggle Full Screen (DesktopApplicationMenu.ts:258-268).
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        NSApp.mainMenu = makeMainMenu()
        // Development: `--appearance light|dark` sets the app's own appearance, leaving the system's alone.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
            ThemeLibrary.shared.controlsAppearance = false
        }
        ThemeLibrary.shared.start()
        AppIconChoice.start()
        quitOnSIGTERM()
        DispatchQueue.global(qos: .utility).async { ComposerController.pruneAttachmentCache() }
        showMainWindow()
        LaunchTiming.mark("window built")
        if CommandLine.arguments.contains("--gallery") { showGallery(nil) }
        if CommandLine.arguments.contains("--pull-request-sample") { PullRequestsGallery.openWindow() }
        NSApp.activate()
        if let i = args.firstIndex(of: "--desktop-managed-preview"), args.indices.contains(i + 1) { desktopManaged?.preview(args[i + 1]) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { notifications?.willTerminate(); desktopManaged?.shutdown() }

    /// T3 holds a single-instance lock (DesktopClerk.ts:122-131): a second launch focuses the first window
    /// (`second-instance`, :186-196) and quits. Development launches (any `--` flag) may run side by side.
    private func handOffToRunningInstance() -> Bool {
        guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }),
              let id = Bundle.main.bundleIdentifier,
              let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != .current })
        else { return false }
        other.activate()
        NSApp.terminate(nil)
        return true
    }

    /// `open-url` (DesktopClerk.ts:183-185): `t3code://auth/codex` starts a ChatGPT sign-in handoff,
    /// `t3code://app/welcome` and `/settings/...` return to provider setup, and a pairing link adds the
    /// environment. Debug builds register `candywrapper-dev` instead of `t3code` (project.yml).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard pendingURLs == nil else {
            pendingURLs?.append(contentsOf: urls)
            return
        }
        for url in urls { handle(url) }
    }

    private static let urlScheme = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
        .first.flatMap { ($0["CFBundleURLSchemes"] as? [String])?.first } ?? "t3code"

    func handle(_ url: URL) {
        switch DesktopOpenURL.parse(url.absoluteString, scheme: Self.urlScheme) {
        case .codexAuthHandoff(let handoff):
            codexAuth.receive(handoff) { [weak self] error in
                self?.mainWindow?.makeKeyAndOrderFront(nil)
                self?.threads?.panel.toasts.show(ToastView(title: "Could not complete ChatGPT sign-in", message: error, kind: .error))
            }
        case .resume(let destination):
            NSApp.activate()
            mainWindow?.makeKeyAndOrderFront(nil)
            if destination.path == "/welcome" { welcomeOnboarding?.show(); return }
            // ponytail: settings resumes at the page; target the provider instance when the provider editor supports resume ids
            if let section = Self.settingsSection(destination.path) {
                sidebarCommands?.closeUtilityPage()
                settings?.open()
                settings?.show(section)
            }
        case .pairing(let host, let code):
            NSApp.activate()
            mainWindow?.makeKeyAndOrderFront(nil)
            sidebarCommands?.closeUtilityPage()
            settings?.openPairingLink(host: host, code: code)
        case .promptLink(let link):
            NSApp.activate()
            mainWindow?.makeKeyAndOrderFront(nil)
            palette?.openPromptLink(link)
        case nil:
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// T3's settings routes (apps/web/src/routes/settings.*.tsx) to pages.
    static func settingsSection(_ path: String) -> SettingsSection? {
        guard path == "/settings" || path.hasPrefix("/settings/") else { return nil }
        let name = path.dropFirst("/settings".count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch name {
        case "appearance": return .appearance
        case "archived": return .archive
        case "beta": return .beta
        case "connections": return .connections
        case "diagnostics": return .diagnostics
        case "integrations": return .integrations
        case "keybindings": return .keybindings
        case "projects": return .projects
        case "providers": return .providers
        case "scheduled-tasks": return .scheduledTasks
        case "snap-shot": return .snapShots
        case "source-control": return .sourceControl
        case "storage": return .storage
        default: return .general
        }
    }

    /// `kill` sends SIGTERM, which would end the app without stopping the server it started.
    /// Route it through the normal quit.
    private func quitOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminationSignal = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let installing = updater?.quitInstallsUpdate ?? false
        let ask = askBeforeQuit && !installing
        askBeforeQuit = false
        var asked = false
        if ask, let window = mainWindow, ThemeRuntime.isDither(dark: window.effectiveAppearance.isDark) {
            guard confirmDitherQuit() else { returnFromCancelledQuit(); return .terminateCancel }
            asked = true
        }
        // Any quit (the menu, the Dock, a logout) first turns the Orchestrator's "while closed" schedule on. The run loop
        // turns until its machine answered, at most a second and a half, so nothing cancels the quit.
        if !orchestratorHandedOff, let orchestrator, orchestrator.needsQuitHandOff {
            orchestratorHandedOff = true
            var handedOff = false
            orchestrator.handOffBeforeQuit { handedOff = true }
            let deadline = Date().addingTimeInterval(1.6)
            while !handedOff, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }
        return finishQuit(installing: installing, asked: asked)
    }

    private func finishQuit(installing: Bool, asked: Bool) -> NSApplication.TerminateReply {
        guard let server else { environments?.stopAll(); return .terminateNow }
        let reply = server.shouldTerminate(installingUpdate: installing, asked: asked)
        if reply == .terminateCancel { cancelQuit() }
        return reply
    }

    private func cancelQuit() {
        returnFromCancelledQuit()
        // CandyWrapper stays open, so the schedule goes back off.
        if orchestratorHandedOff { orchestratorHandedOff = false; orchestrator?.quitCancelled() }
    }

    /// Set by Cmd-Q and the Quit menu item, so a logout, `kill` or a test snapshot quits without asking.
    private var askBeforeQuit = false

    @objc func quitFromMenu(_ sender: Any?) {
        askBeforeQuit = true
        NSApp.terminate(sender)
    }

    /// Dither asks before every Cmd-Q, as Capy does while connected (its `capy/desktop/Quit` `decide`), in
    /// place of T3's hold. Cancel keeps CandyWrapper running in front.
    private func confirmDitherQuit() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit CandyWrapper?"
        if server?.quitStopsLocalWork == true {
            alert.informativeText = "Quitting stops T3 Code's server on this Mac, which interrupts the running work."
        }
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Hold-to-quit hides the window before it quits (`concealPendingQuitWindow`); a quit cancelled from the
    /// confirmation must bring it back, or CandyWrapper keeps running with no window to see.
    private func returnFromCancelledQuit() {
        guard let window = mainWindow else { return }
        window.alphaValue = 1
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func showMainWindow() {
        let window = MainWindow()
        let sidebar = SidebarContentView()
        sidebar.shelfDefaults = .standard
        // Development: `--fake-t3-connect` swaps T3 Connect's Clerk and relay for in-process fakes and keeps
        // saved environments in a temporary catalog (FakeT3Connect).
        let fakeConnect = CommandLine.arguments.contains("--fake-t3-connect") || (Self.isTestBuild && UserDefaults.standard.bool(forKey: "CandyDevFakeConnect"))
        let environments = fakeConnect ? Environments(sidebar: sidebar, catalog: FakeT3Connect.catalog()) : Environments(sidebar: sidebar)
        self.environments = environments
        desktopManaged = DesktopManagedController(window: window, environments: environments)
        ScheduledTasksStore.shared.environments = environments
        _ = environments.observe { ScheduledTasksStore.shared.environmentsChanged() }
        let t3Connect = T3ConnectController(environments: environments, fake: fakeConnect)
        self.t3Connect = t3Connect
        // Dither's account row follows the T3 Connect account, or this Mac's user when signed out.
        let showAccount = { [weak sidebar, weak t3Connect] in
            guard let sidebar, let t3Connect else { return }
            let p = t3Connect.profile
            let email = p?.identifier ?? ""
            let name = [p?.firstName, p?.lastName].compactMap { $0 }.joined(separator: " ")
            // Sign-out keeps the account client, so only a signed-in Clerk session counts.
            if t3Connect.signedIn != nil {
                sidebar.accountRow.set(name: name.isEmpty ? (email.isEmpty ? "T3 Connect" : email) : name,
                                       image: t3Connect.avatar, initials: p?.initials)
            } else {
                sidebar.accountRow.set(name: NSFullUserName(), image: nil, initials: nil)
            }
        }
        _ = t3Connect.observe(showAccount)
        showAccount()
        let threads = ThreadController(sidebar: sidebar, window: window, environments: environments)
        self.threads = threads
        threads.files.serverConfig = { [weak composer = threads.composer] env in composer?.config(env) }
        let main: NSView = Self.threadPreview() ?? threads.panel
        let layout = SidebarLayoutView(sidebarContent: sidebar, mainContent: main)
        // Every T3 main route covers the inset's grain with a flat `bg-background` (ChatView.tsx:11246,
        // settings.tsx:122, _chat.index.tsx:128), so the official main panel is flat #0a0a0a in dark mode.
        layout.main.showsGrain = false
        window.contentView = layout
        sidebar.actions.toggleSidebar = { [weak layout] in layout?.toggle() }
        // The account row samples CPU and memory only while the sidebar is open.
        layout.onOpenChange = { [weak sidebar] open in sidebar?.accountRow.usage.sidebarOpen = open }
        sidebar.accountRow.usage.sidebarOpen = layout.isOpen
        let settings = SettingsController(window: window, layout: layout, threadSidebar: sidebar, threadPanel: main,
                                          environments: environments, t3: t3Connect)
        settings.composer = threads.composer
        settings.serverUpdates = threads.serverUpdates
        threads.serverUpdates.toasts = { [weak settings, weak threads] in settings?.visibleToasts ?? threads?.panel.toasts }
        threads.serverUpdates.window = { [weak window] in window }
        threads.serverUpdates.isOwnServer = { [weak self] id in self?.server?.ownsLocalServer(id) == true }
        // The desktop bridge's ChatGPT callback (providerAuth.ts:16-47): the window comes forward once the browser returns.
        settings.pageContext.receiveProviderAuthCallback = { [weak self] url in
            guard let self else { throw CancellationError() }
            let callback = try await self.codexAuth.receiveCallback(url)
            NSApp.activate()
            self.mainWindow?.makeKeyAndOrderFront(nil)
            return callback
        }
        settings.pageContext.cancelProviderAuthCallback = { [weak self] url in self?.codexAuth.cancelCallback(url) }
        threads.scripts.saveActions = { [weak settings] writes in
            guard let settings else { return "Settings are unavailable." }
            return await settings.saveActions(writes)
        }
        threads.composer.openProviderSetup = { [weak self, weak settings] in
            self?.sidebarCommands?.closeUtilityPage()
            settings?.open(.providers)
        }
        threads.automations.openSettings = { [weak settings] env, taskId in settings?.openScheduledTasks(environmentId: env, taskId: taskId) }
        environments.onSshFailure = { [weak settings] title, message in settings?.toast(title, message, .error) }
        self.settings = settings
        let commands = SidebarCommands(sidebar: sidebar, window: window, layout: layout, environments: environments, threads: threads)
        self.sidebarCommands = commands
        commands.closeSettings = { [weak settings] in settings?.close(record: false) }
        settings.onThreadViewReturn = { [weak threads] in threads?.focusComposerOnReturn() }
        threads.panel.header.onNewThreadInProject = { [weak threads] in threads?.newThread() }
        threads.panel.header.onThreadMenu = { [weak commands, weak threads] event, view in
            guard let id = threads?.openThreadId else { return }
            // A click opens it under the title's left edge, 4pt down (`openTitleMenuNow`, ChatHeader.tsx:179-184); a right
            // click opens it at the pointer (:218-237).
            let anchor = event.type == .rightMouseDown ? nil : NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
            commands?.showThreadMenu(id, event: event, view: view, anchor: anchor, rename: { [weak threads] in threads?.panel.header.beginTitleRename() })
        }
        let orchestrator = OrchestratorController(environments: environments, sidebar: sidebar, threads: threads)
        self.orchestrator = orchestrator
        orchestrator.showPane = { [weak commands] view in commands?.openUtilityPage(.orchestrator, view: view) }
        orchestrator.closePane = { [weak commands] in commands?.closeUtilityPage() }
        orchestrator.openSettings = { [weak settings, weak commands] in commands?.closeUtilityPage(); settings?.open(.orchestrator) }
        orchestrator.toast = { [weak threads] title, message, kind in threads?.panel.toasts.show(ToastView(title: title, message: message, kind: kind)) }
        let connectors = ConnectorsController(environments: environments)
        self.connectors = connectors
        connectors.toast = { [weak settings] title, message, kind in settings?.toast(title, message, kind) }
        commands.onOrchestratorHidden = { [weak orchestrator] in orchestrator?.paneClosed() }
        commands.extraMenuItems = { [weak orchestrator] id in orchestrator?.menuItems(id) ?? [] }
        commands.performExtra = { [weak orchestrator] choice, id in orchestrator?.perform(choice, id) ?? false }
        sidebar.actions.openSettings = { [weak settings, weak commands] in commands?.closeUtilityPage(); settings?.open() }
        sidebar.accountRow.onOpenMachines = { [weak settings, weak commands] in commands?.closeUtilityPage(); settings?.open(.connections) }
        sidebar.actions.openAutomations = { [weak settings, weak commands] in commands?.closeUtilityPage(); settings?.show(.scheduledTasks) }
        let updater = UpdateController()
        self.updater = updater
        let runtime = RuntimeUpdateController(window: window, current: { [weak self, weak environments, weak threads] in
            guard let id = environments?.primaryId, self?.server?.ownsLocalServer(id) == true,
                  let version = threads?.serverUpdates.descriptor(id)?.serverVersion else { return nil }
            return .init(environmentId: id, version: version)
        }, isExternal: { [weak self, weak environments] in
            guard let id = environments?.primaryId, environments?.state(id)?.status == .connected else { return false }
            return self?.server?.ownsLocalServer(id) != true
        }, restart: { [weak self] target in
            guard let server = self?.server else { throw CancellationError() }
            try await server.updateOwnRuntime(to: target, onStage: { _ in })
        })
        runtimeUpdater = runtime
        threads.serverUpdates.runtimeUpdater = runtime
        runtime.onNotice = { [weak settings, weak threads] title, message, failed in
            (settings?.visibleToasts ?? threads?.panel.toasts)?.show(ToastView(title: title, message: message, kind: failed ? .error : .success))
        }
        runtime.observe { [weak threads] in threads?.serverUpdates.changed() }
        environments.observe { [weak runtime] in runtime?.contextChanged() }
        threads.serverUpdates.observe { [weak runtime] in runtime?.contextChanged() }
        updates = UpdateUI(updater: updater, runtime: runtime, window: window, pill: sidebar.updatePill, settings: settings,
                           toasts: { [weak settings, weak threads] in settings?.visibleToasts ?? threads?.panel.toasts },
                           showWindow: { [weak window] in window?.makeKeyAndOrderFront(nil) })
        let everything = UpdateEverything(updater: updater, environments: environments, serverUpdates: threads.serverUpdates,
                                          pill: sidebar.updatePill, window: window,
                                          toasts: { [weak settings, weak threads] in settings?.visibleToasts ?? threads?.panel.toasts },
                                          providers: { [weak threads] env in threads?.composer.config(env)?.providers ?? [] })
        updateEverything = everything
        everything.account = sidebar.accountRow
        updates?.holdsServerUpdates = { [weak everything] in everything?.holdsServerUpdates ?? false }
        everything.onHoldChange = { [weak self] in self?.updates?.refresh() }
        threads.composer.configObservers.append { [weak everything] _ in everything?.providersChanged() }
        if !Self.isPreview { updater.start(); runtime.start() }
        installShortcuts(window: window, layout: layout, sidebar: sidebar, environments: environments, threads: threads,
                         commands: commands, settings: settings)
        installNotifications(window: window, environments: environments, threads: threads, commands: commands, settings: settings)
        // T3's desktop keeps running threads streaming (RunningThreadKeepAlive.tsx); a preview never connects.
        if !Self.isPreview {
            let keepAlive = RunningThreadKeepAlive(environments: environments)
            keepAlive.openThread = { [weak threads] in threads?.openThreadId }
            keepAlive.takeRetained = { [weak threads] id in threads?.takeRetained(id) }
            keepAlive.retain = { [weak threads] id, store in threads?.retainStore(id, store) }
            threads.keepAlive = keepAlive
        }
        // The Dither art's working wave follows the sidebar's Working status on any connected machine.
        environments.observeShell { [weak environments] in
            guard let environments else { return }
            DitherArtView.working = environments.environmentIds.contains { env in
                environments.session(env) != nil && (environments.snapshot(env)?.threads ?? []).contains {
                    $0.lineage.relationshipToParent != .subagent && $0.archivedAt == nil
                        && SidebarModel.resolveSidebarThreadStatus(SidebarThread($0)) == .working
                }
            }
        }
        slowRPCObserver = NotificationCenter.default.addObserver(forName: SlowRPCRequestTracker.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSlowRPCToast() }
        }
        installQuitHold(window: window, layout: layout)
        openIn = OpenInController(card: threads.panel.lazyDetailsCard, pill: threads.panel.header.pill, git: threads.git, environments: environments, composer: threads.composer,
                                  shortcuts: shortcuts)
        threads.panel.model.openFile = { [weak threads, weak openIn] meta, editor in
            if editor { openIn?.openFile(meta) } else { threads?.files.openLink(meta) }
        }
        if let shortcuts, !Self.isPreview {
            let captures = SnapShotController(window: window, composer: threads.composer, shortcuts: shortcuts)
            snapShots = captures
            settings.pageContext.setupSnapShot = { [weak captures] in captures?.showSetup() }
            settings.pageContext.snapShotReady = { [weak captures] in captures?.ready == true }
        }
        // `resolveInitialMainWindowBounds` (DesktopWindow.ts:194-205): a saved frame comes back only when
        // one connected display holds all of it, so a display that is gone or now runs at another scale
        // cannot leave the window off screen. Otherwise the default size, centered. AppKit would pull a
        // stray frame partly back instead, so the check reads the saved frame before AppKit applies it.
        let savedKey = "NSWindow Frame MainWindow"
        if let s = UserDefaults.standard.string(forKey: savedKey)?.split(separator: " ").compactMap({ Double($0) }), s.count >= 4,
           !NSScreen.screens.contains(where: { $0.frame.contains(NSRect(x: s[0], y: s[1], width: s[2], height: s[3])) }) {
            UserDefaults.standard.removeObject(forKey: savedKey)
        }
        window.center()
        window.setFrameAutosaveName("MainWindow")
        if !NSScreen.screens.contains(where: { $0.frame.contains(window.frame) }) {
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 780), display: false)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.layoutTrafficLights()
        mainWindow = window
        if CommandLine.arguments.contains("--chrome-check") { chromeCheck(window, toggle: sidebar.trigger) }
        let welcome = WelcomeOnboardingController(window: window, environments: environments, composer: threads.composer, settings: settings)
        welcomeOnboarding = welcome
        welcome.toasts = threads.panel.toasts
        // `openNewThread(projectRef)` once the wizard lands on an imported project (routes/welcome.tsx:48-56).
        welcome.openProject = { [weak threads, weak sidebar] env, local in
            let id = ProjectId(local).scoped(to: env)
            guard let project = sidebar?.snapshot?.projects.first(where: { $0.id == id }) else { return false }
            threads?.newThread(in: project)
            return true
        }
        chatGptWelcome = ChatGptWelcomeCoordinator(window: window, environments: environments, composer: threads.composer)
        var showedWelcome = false
        let priorLiveShell = environments.onLiveShell
        environments.onLiveShell = { [weak welcome, weak environments, weak composer = threads.composer] env, snapshot in
            priorLiveShell?(env, snapshot)
            composer?.liveShell(env, snapshot)
            welcome?.liveShell(env, snapshot: snapshot)
            if !showedWelcome, CommandLine.arguments.contains("--welcome"), env == environments?.primaryId {
                showedWelcome = true
                welcome?.show()
            }
        }
        if !Self.isPreview && !CommandLine.arguments.contains("--welcome") { welcome.beginFirstRun() }
        startSession(environments, window: window)
        if !Self.isPreview { t3Connect.start() }
        scheduleSelfSnapshot(window)
        PerfScroll.schedule(window)
        let early = pendingURLs ?? []
        pendingURLs = nil
        for url in early { handle(url) }
    }

    /// Thread notifications, the sound and the dock badge (`ThreadNotificationCoordinator`).
    private func installNotifications(window: NSWindow, environments: Environments, threads: ThreadController, commands: SidebarCommands,
                                      settings: SettingsController) {
        let coordinator = ThreadNotificationCoordinator(environments: environments, window: window)
        coordinator.openThread = { [weak self, weak threads, weak settings, weak commands] in
            guard settings?.isOpen != true else { return nil }
            if let id = self?.orchestrator?.visibleThreadId, let env = id.environmentId { return (env, id.localId) }
            guard commands?.isUtilityPageOpen != true, let id = threads?.openThreadId, let env = id.environmentId else { return nil }
            return (env, id.localId)
        }
        coordinator.toasts = { [weak threads, weak settings] in settings?.visibleToasts ?? threads?.panel.toasts }
        coordinator.navigate = { [weak threads, weak settings, weak commands] env, local in
            settings?.close()
            commands?.closeUtilityPage()
            threads?.open(ThreadId(EnvironmentScope.key(env, local.rawValue)))
        }
        settings.chooseNotificationMode = { [weak coordinator] mode in await coordinator?.choose(mode) }
        shortcuts?.onKeyDown = { [weak coordinator] in coordinator?.noteUserGesture() }
        notifications = coordinator
    }

    /// Hold-to-quit on Cmd+Q in the main window (`makeQuitShortcutHandler`, DesktopWindow.ts:642-679) and its overlay.
    private func installQuitHold(window: NSWindow, layout: NSView) {
        var shownMode: QuitHoldController.Mode?
        let controller = QuitHoldController(
            // Dither confirms with a dialog instead (`confirmDitherQuit`), so the first press asks.
            getMode: { [weak window] in
                if let window, ThemeRuntime.isDither(dark: window.effectiveAppearance.isDark) { return .direct }
                return QuitHoldController.Mode(rawValue: ClientSettingsStore.shared.current.string("confirmQuit")) ?? .hold
            },
            notify: { [weak self, weak layout] hint in
                guard let self else { return }
                switch hint {
                case .down(let mode):
                    shownMode = mode
                    let overlay = self.quitOverlay ?? QuitHoldOverlayView()
                    self.quitOverlay = overlay
                    // Keep it above pages added since.
                    if let layout, layout.subviews.last !== overlay { layout.addSubview(overlay) }
                    overlay.show(mode)
                case .up:
                    self.quitOverlay?.hide(after: shownMode)
                }
            },
            // `concealPendingQuitWindow`: leave full screen and go transparent while the keys are still down.
            concealWindow: { [weak window] in
                guard let window else { return }
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                window.alphaValue = 0
            },
            quit: { [weak self] in self?.quitFromMenu(nil) })
        shortcuts?.quitHold = controller
        quitHold = controller
    }

    /// One keyboard shortcut dispatcher for the window, fed by T3's keybindings (`Shortcuts`).
    private func installShortcuts(window: NSWindow, layout: SidebarLayoutView, sidebar: SidebarContentView, environments: Environments,
                                  threads: ThreadController, commands: SidebarCommands, settings: SettingsController) {
        threads.permissionNotice.openConnections = { [weak settings] in settings?.open(); settings?.show(.connections) }
        threads.git.openSourceControlSettings = { [weak settings] in settings?.open(); settings?.show(.sourceControl) }
        let shortcuts = Shortcuts(window: window)
        threads.panel.model.onFrameShortcut = { [weak shortcuts] stroke in shortcuts?.run(stroke) }
        let guestShare = GuestShareController(environments: environments, threads: threads)
        commands.guestShare = guestShare
        let palette = PaletteCommands(window: window, sidebar: sidebar, environments: environments, threads: threads,
                                      commands: commands, settings: settings)
        palette.guestShare = guestShare
        shortcuts.context = { [weak window, weak threads, weak commands] in
            var values = threads?.composer.shortcutContext ?? [:]
            values["editableFocus"] = Shortcuts.editableFocused(in: window)
            values["draftThreadRoute"] = threads?.panel.isDraft ?? false
            values["rightPanelOpen"] = threads?.panel.rightPanelOpen ?? false
            values["terminalFocus"] = threads?.terminal.isFocused ?? false
            values["terminalOpen"] = threads?.panel.terminalOpen ?? false
            values["previewFocus"] = threads?.browser.isFocused ?? false
            values["usagePageOpen"] = commands?.isUsagePageOpen ?? false
            return KeybindingContext(values)
        }
        // A collapsed sidebar hides the undo notice, so text fields keep their own undo (AppSidebarLayout.tsx:267-268 in 3473).
        shortcuts.undoClaimsShortcut = { [weak layout, weak commands] in layout?.isOpen == true && commands?.ledger.claimsShortcut == true }
        shortcuts.releaseUndoShortcut = { [weak commands] in commands?.ledger.releaseShortcut() }
        shortcuts.observeTextEdits()
        // The theme editor floats above every page (ThemeEditorHost above the router).
        let editor = ThemeEditorController.shared
        editor.host = layout
        editor.toast = { [weak settings, weak threads] title, message, kind in
            if settings?.isOpen == true { settings?.toast(title, message, kind) } else {
                threads?.panel.toasts.show(ToastView(title: title, message: message, kind: kind))
            }
        }
        // `themeEditor.toggle` (CommandPalette.tsx:557-565).
        shortcuts.on("themeEditor.toggle") { _ in
            editor.toggle(initialAppearance: ThemeLibrary.shared.resolvedAppearance)
            return true
        }
        // `sidebar.toggle` (AppSidebarLayout.tsx:96-135).
        shortcuts.on("sidebar.toggle") { [weak layout] _ in
            layout?.toggle()
            return true
        }
        // The scope popup's settings button, the thread menu's Project settings (`/projects/$projectKey`).
        sidebar.actions.openProjectSettings = { [weak palette] key in palette?.openProjectSettings(key) }
        settings.chooseIconFile = { [weak palette] env, cwd, name, external, onSelect in
            palette?.openProjectFaviconPicker(environmentId: env, cwd: cwd, projectName: name, external: external, onSelect: onSelect)
        }
        commands.openProjectSettings = { [weak palette] key in palette?.openProjectSettings(key) }
        // The header's new-thread button: with several projects the palette's "New thread in..." (Sidebar.tsx:4944-4962).
        sidebar.actions.newThread = { [weak palette] in palette?.newThreadFromSidebar(shift: NSEvent.modifierFlags.contains(.shift)) }
        commands.openAddProject = { [weak palette] in palette?.openAddProject() }
        // The no-projects hero (NoProjectsHero.tsx).
        threads.offersScratch = { [weak palette, weak environments] in palette?.scratchEnvironmentId(environments?.primaryId) != nil }
        threads.noProjectsHero.addProject.action = { [weak commands] in commands?.addProject() }
        threads.composer.onAddProject = { [weak commands] in commands?.addProject() }
        threads.composer.scratchEnvironment = { [weak palette] in palette?.scratchTargetEnvironmentId }
        threads.composer.onStartWithoutProject = { [weak palette] env in palette?.startScratchThread(env) }
        threads.composer.onManageProjects = { [weak commands, weak settings] in
            commands?.closeUtilityPage()
            settings?.open()
            settings?.show(.projects)
        }
        threads.noProjectsHero.startWithoutProject.action = { [weak palette, weak environments] in
            guard let palette, let env = palette.scratchEnvironmentId(environments?.primaryId) else { return }
            palette.startScratchThread(env)
        }
        let updateToast = ProviderUpdateLaunchToast(viewport: threads.panel.toasts)
        providerUpdateToast = updateToast
        updateToast.openSettings = { [weak settings] in settings?.show(.providers) }
        // ponytail: no `providers:manage` check before Update; the server refuses a connection without it and the rejected toast says so
        updateToast.request = { [weak environments] method, payload in
            guard let environments, let env = environments.primaryId else { throw Environments.CommandError.notConnected }
            return try await environments.request(env, method, payload)
        }
        // The provider update pill follows the primary environment's providers (`primaryServerProvidersAtom`).
        threads.composer.configObservers.append { [weak sidebar, weak threads, weak environments, weak updateToast] env in
            guard env == environments?.primaryId, let providers = threads?.composer.config(env)?.providers else { return }
            sidebar?.providerUpdatePill.update(providers)
            updateToast?.update(providers)
        }
        sidebar.providerUpdatePill.onOpenSettings = { [weak settings, weak commands] in
            commands?.closeUtilityPage()
            settings?.open()
            settings?.show(.providers)
        }
        // Route history for `navigation.back` and `navigation.forward` (AppSidebarLayout.tsx:168-213).
        let history = RouteHistory()
        let currentRoute: () -> RouteHistory.Route? = { [weak settings, weak commands, weak threads] in
            if let settings, settings.isOpen { return .settings(settings.section) }
            if let page = commands?.openUtilityKind {
                switch page {
                case .pullRequests: return .pullRequests
                case .usage: return .usage
                case .orchestrator: return .orchestrator
                }
            }
            switch threads?.composer.target {
            case .thread(let id)?: return .thread(id)
            case .draft(let s)?: return .draft(s.draftId)
            case nil: return nil
            }
        }
        let record: () -> Void = { [weak history, weak threads] in
            let route = currentRoute()
            history?.record(route)
            threads?.syncVisit()
            if case .thread? = route { threads?.costRouteShowsThread = true } else { threads?.costRouteShowsThread = false }
            threads?.browser.threadRouteChanged()
        }
        threads.onRouteChange = record
        settings.onRouteChange = record
        commands.onRouteChange = record
        // The brand links to "/" (SidebarChrome.tsx:110-123), which lands on a draft for the most recent
        // project (_chat.index.tsx `IndexDraftLanding`), from the thread view, Settings or a utility page.
        let goHome = { [weak settings, weak commands, weak threads] in
            commands?.closeUtilityPage(record: false)
            settings?.close(record: false)
            threads?.landOnIndex()
            record()
        }
        sidebar.actions.goHome = goHome
        settings.onHome = goHome
        (window as? MainWindow)?.onUnhandledEscape = { [weak settings, weak window] in
            guard let settings, settings.isOpen, settings.modal == nil else { return false }
            // Only from Settings itself: an overlay or dialog elsewhere in the window keeps its Escape.
            if let focus = window?.firstResponder as? NSView, focus !== window?.contentView,
               !focus.isDescendant(of: settings.nav), !focus.isDescendant(of: settings.page) { return false }
            settings.escape()
            return true
        }
        history.apply = { [weak settings, weak commands, weak threads, weak sidebar] route in
            guard let settings, let commands, let threads, let sidebar else { return false }
            switch route {
            case .thread(let id):
                guard sidebar.snapshot?.threads.contains(where: { $0.id == id && $0.archivedAt == nil }) == true else { return false }
                settings.close(); commands.closeUtilityPage(); threads.open(id)
            case .draft(let draftId):
                guard threads.composer.hasDraft(draftId) else { return false }
                settings.close(); commands.closeUtilityPage(); sidebar.actions.openDraft(draftId)
            case .settings(let section):
                commands.closeUtilityPage(); settings.open(); settings.show(section)
            case .pullRequests:
                settings.close(); commands.openUtilityPage(.pullRequests)
            case .usage:
                settings.close(); commands.openUtilityPage(.usage)
            case .orchestrator:
                guard let orchestrator = self.orchestrator, OrchestratorStore.shared.isActive else { return false }
                settings.close(); orchestrator.open()
            }
            return true
        }
        shortcuts.on(["navigation.back", "navigation.forward"]) { [weak history] call in
            guard let history else { return false }
            if call.command == "navigation.back" { history.back() } else { history.forward() }
            return true
        }
        self.routeHistory = history
        // Capy's + opens the new-thread page for the current project; its project chip picks another.
        // Redesign's header controls sit at the right of the tab band (they hide with the thread panel).
        layout.tabStrip.trailingAccessory = self.threads?.panel.header.pill
        ditherTabs = DitherTabsController(layout: layout, sidebar: sidebar, history: history, current: currentRoute,
                                          newThread: { [weak palette] opened in palette?.newThreadFromSidebar(shift: true, then: opened) })
        commands.historyBack = { [weak history] in history?.back() ?? false }
        commands.closePalette = { [weak palette] in palette?.close() }
        // Escape drops a multi-selection (_chat.tsx:98-102). Settings and Usage sit outside the chat layout,
        // so there Escape only goes back (useEscapeToGoBack, UsagePage.tsx:115).
        shortcuts.onKey { [weak sidebar, weak settings, weak commands] event in
            guard let sidebar, settings?.isOpen != true, commands?.isUsagePageOpen != true else { return false }
            return sidebar.escapeClearsSelection(event)
        }
        shortcuts.onKey { [weak panel = threads.panel] event in
            guard event.charactersIgnoringModifiers?.lowercased() == "f", event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  let panel, panel.panelState.isOpen, panel.panelState.active?.kind == .diff,
                  let responder = panel.window?.firstResponder as? NSView, let diff = panel.lazyDiffPanel.loaded, responder.isDescendant(of: diff) else { return false }
            diff.showFind(); return true
        }
        threads.registerShortcuts(shortcuts)
        commands.registerShortcuts(shortcuts) { [weak threads] in threads?.composer.pickers.isModelPickerOpen ?? false }
        palette.registerShortcuts(shortcuts)
        settings.registerShortcuts(shortcuts)
        self.shortcuts = shortcuts
        palette.togglePerformanceHUD = { [weak self] in self?.togglePerformanceHUD(nil) }
        self.palette = palette
        installMenuBar(window: window, palette: palette, threads: threads)
    }

    /// The menu bar item (Capy's tray, docs/research/capy-menubar.md). Each action brings the window forward first.
    private func installMenuBar(window: NSWindow, palette: PaletteCommands, threads: ThreadController) {
        guard !Self.isPreview else { return }
        let menuBar = MenuBarController(snapshot: { [weak palette] in palette?.snapshot })
        let show = { [weak window] in
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
        menuBar.openThread = { [weak palette, weak threads] id in
            show()
            palette?.showThreadView()
            threads?.open(id)
        }
        menuBar.viewAllThreads = { [weak palette] in show(); palette?.open() }
        menuBar.newThread = { [weak palette] in show(); palette?.newThreadFromSidebar(shift: false) }
        menuBar.quit = { [weak self] in self?.quitFromMenu(nil) }
        self.menuBar = menuBar
    }

    /// Development: `--thread-preview [title prefix]` shows a recorded thread from
    /// fixtures/transcripts/04-threads.jsonl in the main panel (default: the markdown thread).
    private static var isPreview: Bool { CommandLine.arguments.contains("--thread-preview") }

    private static func threadPreview() -> NSView? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--thread-preview") else { return nil }
        let title = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : ThreadPreview.markdownThread
        #if DEBUG
        // Isolated test builds can replay a sandbox projection and its local image files.
        if isTestBuild, title.hasPrefix("/"), title.hasSuffix(".json"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: title)),
           let projection = try? JSONDecoder().decode(ThreadProjection.self, from: data) {
            let panel = ThreadPanelView()
            let directory = URL(fileURLWithPath: title).deletingLastPathComponent()
            panel.model.attachmentImage = { id, side, cover in
                let file = directory.appendingPathComponent((id as NSString).lastPathComponent + ".png")
                return await ComposerImageIO.thumbnail(file, side: side, cover: cover, measurementKey: id)
            }
            panel.model.onExpandImage = { [weak panel] items, index in
                guard let window = panel?.window else { return }
                ExpandedImagePreviewView(items: items, index: index).present(in: window)
            }
            panel.setProjection(projection, projectTitle: "Layout sandbox", workspaceRoot: directory.path)
            if args.contains("--preview-details") {
                panel.setDetailsOpen(true); panel.setDetailsInlineOpen(true)
                panel.detailsCard.runContext.text = "Local sandbox"
                panel.detailsCard.branch.text = "main"
                panel.detailsCard.gitActions.primary.text = "Commit & push"
                panel.detailsCard.gitActions.primary.icon = IconName.cloudUpload.definition
                panel.detailsCard.totals.insertions = 42
                panel.detailsCard.totals.deletions = 8
            }
            if args.contains("--preview-browser") {
                panel.miniPlayerShown = true
                panel.miniPlayer.onClose = { [weak panel] in panel?.miniPlayerShown = false }
            }
            return panel
        }
        #endif
        guard let projection = try? ThreadPreview.projection(titled: title) else { return nil }
        let panel = ThreadPanelView()
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        return panel
    }

    /// Development: `--snapshot <png> [--snapshot-delay seconds]` renders the window's own layer
    /// tree to a PNG (no screen-recording permission needed) and quits.
    private func scheduleSelfSnapshot(_ window: NSWindow) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let delay = args.firstIndex(of: "--snapshot-delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                guard let view = window.contentView, let layer = view.layer else { return }
                let scale: CGFloat = 2, size = view.bounds.size
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
                if view.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
                layer.render(in: ctx)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("snapshot:", path)
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }

    /// The local server through `ServerController`, plus every saved environment. Development:
    /// `--server <url> --token-file <path>` connects straight to a running server instead, such as the
    /// sandbox on 47391. Give the pair more than once for more environments: the first is the primary
    /// (this machine), the rest are remote. They aren't saved.
    private func startSession(_ environments: Environments, window: NSWindow) {
        let args = CommandLine.arguments
        // A preview never connects, so it never starts or joins a server.
        if args.contains("--thread-preview") { return }
        var servers = Self.developmentServers(args)
        // A test build relaunched by its updater gets no arguments; its own defaults can name the server
        // (`defaults write <test bundle id> CandyDevServer <url>`, and `CandyDevTokenFile <path>`).
        if servers.isEmpty, Self.isTestBuild, let url = UserDefaults.standard.string(forKey: "CandyDevServer"),
           let file = UserDefaults.standard.string(forKey: "CandyDevTokenFile") {
            servers = Self.developmentServers(["--server", url, "--token-file", file])
        }
        guard servers.isEmpty else {
            for (i, server) in servers.enumerated() { environments.addDevelopment(baseURL: server.url, token: server.token, primary: i == 0) }
            // Saved environments connect at launch whatever the primary is, as in T3.
            environments.restoreSaved()
            return
        }
        let server = ServerController(environments: environments, window: window)
        server.onRuntimeRecovery = { [weak self] message in self?.runtimeUpdater?.onNotice?("Server update recovery", message, false) }
        // The first start on a Mac without T3 Code installs CandyWrapper's own runtime; a toast shows how far it got.
        var installToast: (id: Int, view: ToastView)?
        server.onInstallProgress = { [weak self] version, progress in
            guard let toasts = self?.threads?.panel.toasts else { return }
            guard let progress else {
                if let t = installToast { toasts.dismiss(t.id) }
                installToast = nil
                return
            }
            let title = "Installing T3 Code \(version)"
            let message: String = switch progress {
            case .downloading(let received, let total?): "Downloading \(received / 1_000_000) of \(total / 1_000_000) MB…"
            case .downloading: "Downloading…"
            case .verifying: "Checking the download…"
            case .extracting: "Unpacking…"
            }
            if let t = installToast { t.view.setText(title: title, message: message); return }
            let view = ToastView(title: title, message: message, kind: .loading)
            installToast = (toasts.show(view, timeout: 0), view)
        }
        // A terminal running a build keeps the server from idle-stopping, which would kill the build.
        server.runningTerminals = { [weak self] id in self?.threads?.terminal.runningSubprocesses(environmentId: id) ?? 0 }
        threads?.terminal.onActivityChanged = { [weak server] in server?.reportActivity() }
        server.start()
        self.server = server
        environments.restoreSaved()
    }

    /// The `--server` and `--token-file` values, paired in order. A pair whose token file can't be read is skipped.
    static func developmentServers(_ args: [String]) -> [(url: URL, token: String)] {
        func values(_ flag: String) -> [String] {
            args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
        }
        return zip(values("--server"), values("--token-file")).compactMap { server, file in
            guard let url = URL(string: server),
                  let token = try? String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return nil }
            return (url, token)
        }
    }

    /// Prints traffic light frames and what a click at header points would hit, then quits.
    private func chromeCheck(_ window: MainWindow, toggle: NSView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let frame = window.contentView!.superview!
                for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    if let button = window.standardWindowButton(b) {
                        let r = button.convert(button.bounds, to: nil)
                        print("chrome:", b.rawValue, "x", r.minX, "centerY from top", window.frame.height - r.midY)
                    }
                }
                let toggleCenter = toggle.convert(NSPoint(x: 14, y: 14), to: nil)
                for (name, point) in [("toggle", toggleCenter), ("header", NSPoint(x: 400, y: window.frame.height - 26)),
                                      ("body", NSPoint(x: 400, y: 300))] {
                    let hit = frame.hitTest(frame.convert(point, from: nil))
                    print("chrome: hit", name, hit.map { String(describing: type(of: $0)) } ?? "nil",
                          "canMoveWindow", hit?.mouseDownCanMoveWindow ?? false)
                }
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }

    @objc func checkForUpdates(_ sender: Any?) { updates?.menuCheck() }

    /// Sandbox and performance builds have separate defaults and file-backed drafts/stashes. Only they read
    /// development defaults that stand in for launch arguments, so a stray default cannot redirect the shipped app.
    static let isTestBuild = Bundle.main.bundleIdentifier?.hasPrefix("dev.candywrapper.test.") == true
        || Bundle.main.bundleIdentifier == "dev.candywrapper.perf"

    @objc func showGallery(_ sender: Any?) {
        if galleryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Component Gallery"
            window.isReleasedWhenClosed = false
            ComponentGallery.extraSections = [MarkdownGallery.section] + DiffGallery.sections + PickersGallery.sections + PullRequestsGallery.sections
            window.contentView = ComponentGallery.makeView()
            window.center()
            galleryWindow = window
        }
        galleryWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        // T3's menu template (apps/desktop/src/window/DesktopApplicationMenu.ts:166-245), the parts that
        // exist here.
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About CandyWrapper", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        // "Check for Updates..." after About (DesktopApplicationMenu.ts:169-172).
        appMenu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // `Settings...` with CmdOrCtrl+, sends `open-settings` (DesktopApplicationMenu.ts:176-180).
        appMenu.addItem(withTitle: "Settings...", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide CandyWrapper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Allow Remote Access", action: #selector(toggleRemoteAccess(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit CandyWrapper", action: #selector(quitFromMenu(_:)), keyEquivalent: "q")
        // Hidden: the gallery is a developer tool, reachable only by shortcut or --gallery.
        let gallery = NSMenuItem(title: "Component Gallery", action: #selector(showGallery(_:)), keyEquivalent: "g")
        gallery.keyEquivalentModifierMask = [.command, .option, .shift]
        gallery.isHidden = true
        gallery.allowsKeyEquivalentWhenHidden = true
        appMenu.addItem(gallery)
        // Hidden: writes the timeline's row views, frames and layout problems for checking a live thread.
        let timeline = NSMenuItem(title: "Log Timeline Rows", action: #selector(logTimeline(_:)), keyEquivalent: "l")
        timeline.keyEquivalentModifierMask = [.command, .option, .shift]
        timeline.isHidden = true
        timeline.allowsKeyEquivalentWhenHidden = true
        appMenu.addItem(timeline)
        // Hidden: the performance HUD. T3 binds nothing with Option, Shift and Command on P
        // (packages/shared/src/keybindings.ts:124-208), and its matcher wants every modifier equal (:90-96).
        let hud = NSMenuItem(title: "Toggle Performance HUD", action: #selector(togglePerformanceHUD(_:)), keyEquivalent: "p")
        hud.keyEquivalentModifierMask = [.command, .option, .shift]
        hud.isHidden = true
        hud.allowsKeyEquivalentWhenHidden = true
        appMenu.addItem(hud)
        appItem.submenu = appMenu
        // File: `{ role: "close" }` on macOS (DesktopApplicationMenu.ts:192-206).
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = makeEditMenu()
        // View (DesktopApplicationMenu.ts:236-269).
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reloadWorkspace(_:)), keyEquivalent: "r")
        view.addItem(withTitle: "Force Reload", action: #selector(forceReloadWorkspace(_:)), keyEquivalent: "r").keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(resetWorkspaceZoom(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(zoomWorkspaceIn(_:)), keyEquivalent: "=")
        let plus = view.addItem(withTitle: "Zoom In", action: #selector(zoomWorkspaceIn(_:)), keyEquivalent: "+")
        plus.isHidden = true
        plus.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomWorkspaceOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
        // Help holds only "Check for Updates..." (DesktopApplicationMenu.ts:272-279).
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = help
        NSApp.helpMenu = help
        return main
    }

    /// T3's Edit menu: the standard text actions, which the composer's NSTextView handles.
    private func makeEditMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Paste as Text", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let speech = NSMenu(title: "Speech")
        speech.addItem(withTitle: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
        speech.addItem(withTitle: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Speech", action: nil, keyEquivalent: "").submenu = speech
        return edit
    }

    private func updateSlowRPCToast() {
        let requests = SlowRPCRequestTracker.shared.slow
        guard !requests.isEmpty else {
            if let slowRPCToast { slowRPCViewport?.dismiss(slowRPCToast) }
            slowRPCToast = nil
            return
        }
        guard let viewport = slowRPCViewport ?? settings?.visibleToasts ?? threads?.panel.toasts else { return }
        let seconds = Int(requests.map(\.threshold).min() ?? 15)
        let message = "\(requests.count) request\(requests.count == 1 ? "" : "s") waiting longer than \(seconds)s."
        // `SlowRequestDetails` behind the description (SlowRpcRequestToastCoordinator.tsx:19-62).
        let details = (expand: "Show requests", collapse: "Hide requests",
                       items: requests.map { ToastDetailListView.Item(title: $0.method, detail: "Started \($0.startedAt.formatted(date: .omitted, time: .standard))") })
        if let slowRPCToast {
            viewport.update(slowRPCToast, title: "Some requests are slow", message: message)
            viewport.toast(slowRPCToast)?.details = details
        } else {
            slowRPCViewport = viewport
            let toast = ToastView(title: "Some requests are slow", message: message, kind: .warning)
            toast.details = details
            slowRPCToast = viewport.show(toast, timeout: 0)
        }
    }

    @objc func reloadWorkspace(_ sender: Any?) {
        guard let environments else { return }
        for id in environments.environmentIds { environments.reconnect(id) }
    }
    /// T3 reloads the main window ignoring its cache (DesktopWindow.ts:1048): every HTTP response, file read,
    /// image and favicon loads again. Sent attachment copies on disk go too, as the browser cache would.
    @objc func forceReloadWorkspace(_ sender: Any?) {
        URLCache.shared.removeAllCachedResponses()
        try? FileManager.default.removeItem(at: ComposerController.attachmentCacheDirectory)
        ForceReloadCaches.clear()
        threads?.forceReload()
        reloadWorkspace(sender)
    }
    @objc func resetWorkspaceZoom(_ sender: Any?) { (mainWindow as? MainWindow)?.setWorkspaceZoom(0) }
    @objc func zoomWorkspaceIn(_ sender: Any?) { (mainWindow as? MainWindow)?.changeWorkspaceZoom(0.5) }
    @objc func zoomWorkspaceOut(_ sender: Any?) { (mainWindow as? MainWindow)?.changeWorkspaceZoom(-0.5) }

    /// Cmd+Opt+Shift+L: the open thread's timeline report to /tmp/cw-timeline-<pid>.txt and stdout.
    @objc func togglePerformanceHUD(_ sender: Any?) {
        guard let host = mainWindow?.contentView else { return }
        performanceHUD.toggle(in: host)
    }

    @objc func logTimeline(_ sender: Any?) {
        guard let report = threads?.panel.timeline.debugReport() else { return }
        let path = "/tmp/cw-timeline-\(getpid()).txt"
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
        print(report)
        NSLog("timeline report written to %@", path)
    }

    /// Cmd+, : the settings pages, Connections first while it is the only one built. T3 lands on General.
    @objc func openSettings(_ sender: Any?) {
        mainWindow?.makeKeyAndOrderFront(nil)
        sidebarCommands?.closeUtilityPage()
        settings?.open()
    }

    /// On: T3 Code's server keeps running while CandyWrapper is idle, so other devices can reach
    /// this Mac. Off: it stops after 10 idle minutes.
    @objc func toggleRemoteAccess(_ sender: Any?) {
        guard let server else { return }
        server.setAllowsRemoteAccess(!server.allowsRemoteAccess)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleRemoteAccess(_:)) else { return true }
        item.state = server?.allowsRemoteAccess == true ? .on : .off
        return server != nil
    }
}

/// Development: `--perf-scroll <delay seconds>` scrolls the window's tallest scroll view (the
/// timeline) to the top and back to the bottom, 300 pt per frame, then prints `perf-scroll done` to
/// stderr. scripts/perf-review uses it to measure scrolling without sending events through the
/// user's screen.
@MainActor
enum PerfScroll {
    static func schedule(_ window: NSWindow) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--perf-scroll"), i + 1 < args.count, let delay = Double(args[i + 1]) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                guard let content = window.contentView, let scroll = tallest(in: content) else {
                    FileHandle.standardError.write(Data("perf-scroll no scroll view\n".utf8))
                    return
                }
                step(scroll, up: true, left: 140)
            }
        }
    }

    private static func tallest(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var queue = [view]
        while let v = queue.popLast() {
            if let s = v as? NSScrollView, (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = s }
            queue += v.subviews
        }
        return best
    }

    /// One frame's worth of scrolling, then the next on the following frame (16 ms).
    private static func step(_ scroll: NSScrollView, up: Bool, left: Int) {
        guard left > 0 else {
            if up { step(scroll, up: false, left: 140) } else { FileHandle.standardError.write(Data("perf-scroll done\n".utf8)) }
            return
        }
        StallMonitor.arm("perf-scroll")
        let clip = scroll.contentView
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        // Toward the start of the document: y shrinks in a flipped document, grows in an unflipped one.
        let towardTop: CGFloat = (scroll.documentView?.isFlipped ?? true) ? -300 : 300
        let y = min(maxY, max(0, clip.bounds.origin.y + (up ? towardTop : -towardTop)))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
            MainActor.assumeIsolated { step(scroll, up: up, left: left - 1) }
        }
    }
}
