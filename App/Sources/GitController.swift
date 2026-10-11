import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// The branch toolbar and git actions for the open thread or draft (BranchToolbar.tsx,
/// BranchToolbarBranchSelector.tsx, GitActionsControl.tsx, ThreadDetailsPanel.tsx).
///
/// It follows `subscribeVcsStatus` for the workspace the thread runs in (its worktree, else the project root)
/// on the thread's own environment, and asks `vcs.refreshStatus` when the window comes forward (debounced
/// 250 ms) and when the git menu opens. It drives the draft composer's context strip (run context and
/// branch) and the thread details card (run context, branch, the git actions split button, Changes or
/// Initialize Git), opens the branch picker (`vcs.listRefs` pages, `vcs.switchRef`, `vcs.createRef`), runs
/// `git.runStackedAction` (commit, push, create PR and the stacked forms) with its progress events, `vcs.pull`,
/// `vcs.init` and the publish wizard (`server.discoverSourceControl`, `sourceControl.publishRepository`).
/// A draft's picks (workspace mode, branch, worktree, start from origin) live in its `DraftSession`.
@MainActor
final class GitController {
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private let composer: ComposerController
    private var modal: ModalHost?
    /// Settings > Source Control, set by the app.
    var openSourceControlSettings: (() -> Void)?

    /// What the toolbar works on.
    struct Target: Equatable {
        var environmentId: String
        /// The server thread, nil for a draft.
        var threadId: ThreadId?
        var projectId: ProjectId
        var projectRoot: String
        var branch: String?
        var worktreePath: String?
        var envMode: EnvMode
        var startFromOrigin: Bool
        /// The workspace the thread runs in (`branchCwd`, `gitCwd`).
        var cwd: String { worktreePath ?? projectRoot }
        var isDraft: Bool { threadId == nil }
    }

    private(set) var target: Target?
    private(set) var status: VcsStatus?
    private var statusKey: String?
    private var statusTask: Task<Void, Never>?
    /// The first page of refs for the target's workspace (no query): the worktree base default and the
    /// remote check on the trigger label.
    private var refs: [VcsRef] = []
    private var refsLoaded = false
    private var refsKey: String?
    private var optimisticBranch: String?
    private var branchActionPending = false

    /// A running `git.runStackedAction` or `vcs.pull` (`vcsActionManager` state).
    private struct Running {
        var isPull: Bool
        var label: String?
        var phaseLabel: String?
        var output: String?
        var startedAt = Date()
        var hookStartedAt: Date?
    }
    private var running: Running?
    private var success: (title: String, description: String?, key: String)?
    private var successWork: DispatchWorkItem?
    private var tick: Timer?
    private var focusWork: DispatchWorkItem?

    private var picker: (view: BranchPickerView, popup: OpenPopup, query: String, pages: [VcsListRefsResult], inPanel: Bool)?
    /// The open "Checkout pull request" dialog and its resolve debounce.
    private var checkoutDialog: PullRequestThreadDialog?
    private var resolveTask: Task<Void, Never>?
    static let checkoutPrefix = "__checkout_pull_request__:"
    private var pickerSeq = 0

    /// The details card is per thread in T3 (`threadPanelVisibilityByThreadKey`); kept app-wide here.
    // ponytail: one open state for every thread, closed by default; T3 opens the inline card by default when it fits
    private static let detailsOpenKey = "thread.detailsCardOpen"

    init(panel: ThreadPanelView, sidebar: SidebarContentView, environments: Environments, composer: ComposerController) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        self.composer = composer
        panel.setDetailsOpen(UserDefaults.standard.bool(forKey: Self.detailsOpenKey))
        panel.onDetailsToggle = { [weak self] in self?.toggleDetails() }
        let strip = panel.contextStrip
        strip.runContext.action = { [weak self] in self?.openRunContextMenu(inPanel: false) }
        strip.branch.action = { [weak self] in self?.openBranchPicker(inPanel: false) }
        let card = panel.detailsCard
        card.runContext.action = { [weak self] in self?.openRunContextMenu(inPanel: true) }
        let branchMenu: (NSEvent, NSView) -> Void = { [weak self] event, view in
            guard let name = self?.resolvedBranch, !name.isEmpty else { return }
            let menu = SidebarCommands.nativeMenu([ThreadMenuItem("copy", "Copy branch name")]) { _ in
                NSPasteboard.general.clearContents()
                let copied = NSPasteboard.general.setString(name, forType: .string)
                AnchoredCopyToast.show(from: view, success: copied)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        strip.branch.onContextMenu = branchMenu
        card.branch.onContextMenu = branchMenu
        card.branch.action = { [weak self] in self?.openBranchPicker(inPanel: true) }
        card.gitActions.primary.action = { [weak self] in self?.runQuickAction() }
        card.gitActions.secondary.action = { [weak self] in self?.openGitMenu() }
        card.initGit.action = { [weak self] in self?.initializeGit() }
        card.changes.action = { [weak self] in self?.panel.toggleDiff() }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = ObjectIdentifier(note.object as AnyObject)
            MainActor.assumeIsolated {
                guard let self, let own = self.panel.window, ObjectIdentifier(own) == window else { return }
                self.scheduleFocusRefresh()
            }
        }
    }

    // MARK: Target

    /// The open thread or draft changed, or the shell did (a thread's branch or worktree moved).
    func refresh() {
        let next = resolveTarget()
        if next != target {
            if next?.cwd != target?.cwd || next?.environmentId != target?.environmentId {
                optimisticBranch = nil
                success = nil
            }
            target = next
        }
        let key = target.map { "\($0.environmentId)\u{0}\($0.cwd)" }
        if key != statusKey {
            statusKey = key
            status = nil
            refs = []
            refsLoaded = false
            refsKey = nil
            subscribeStatus()
            loadRefs()
        }
        render()
    }

    func sessionChanged(_ environmentId: String) {
        guard target?.environmentId == environmentId else { return }
        statusKey = nil
        refresh()
    }

    private func resolveTarget() -> Target? {
        guard let snapshot = sidebar?.snapshot else { return nil }
        if let draft = composer.currentDraft {
            let projectId = ProjectId(draft.projectId)
            guard let project = snapshot.projects.first(where: { $0.id == projectId }), let env = projectId.environmentId else { return nil }
            let mode = draft.envMode ?? (project.defaultThreadEnvMode == "worktree" ? .worktree : .local)
            return Target(environmentId: env, threadId: nil, projectId: projectId, projectRoot: project.workspaceRoot,
                          branch: draft.branch, worktreePath: forceNewWorktree ? nil : draft.worktreePath,
                          envMode: forceNewWorktree ? .worktree : BranchToolbarLogic.draftEnvMode(worktreePath: draft.worktreePath, draftMode: mode),
                          startFromOrigin: draft.startFromOrigin ?? false)
        }
        guard let id = panel.isDraft ? nil : composer.openThreadId,
              let thread = snapshot.threads.first(where: { $0.id == id }) ?? snapshot.archivedThreads.first(where: { $0.id == id }),
              let project = snapshot.projects.first(where: { $0.id == thread.projectId }), let env = id.environmentId else { return nil }
        let worktree = thread.worktreePath.flatMap { $0.isEmpty ? nil : $0 }
        return Target(environmentId: env, threadId: id, projectId: thread.projectId, projectRoot: project.workspaceRoot,
                      branch: thread.branch, worktreePath: worktree, envMode: worktree != nil ? .worktree : .local, startFromOrigin: false)
    }

    private var shell: ShellSession? { environments.session(target?.environmentId) }

    // MARK: Status

    private func subscribeStatus() {
        statusTask?.cancel()
        statusTask = nil
        guard let target, let shell else { return }
        let cwd = target.cwd, key = statusKey
        statusTask = shell.supervisor.subscribe(VcsRPC.subscribeStatus, payload: { VcsRPC.cwd(cwd) }, handler: { [weak self] event in
            guard case .value(let json) = event else { return }
            await MainActor.run {
                guard let self, self.statusKey == key else { return }
                self.status = VcsStatus.apply(json, to: self.status)
                self.statusChanged()
            }
        })
    }

    /// `vcs.refreshStatus`: the server re-reads the workspace and pushes the change on the stream.
    private func refreshStatus() {
        guard let target, let shell else { return }
        let key = statusKey
        Task { [weak self] in
            guard let value = try? await shell.supervisor.request(VcsRPC.refreshStatus, payload: VcsRPC.cwd(target.cwd)),
                  let fresh = try? value.decode(as: VcsStatus.self) else { return }
            guard let self, self.statusKey == key else { return }
            self.status = fresh
            self.statusChanged()
        }
    }

    /// `GIT_STATUS_WINDOW_REFRESH_DEBOUNCE_MS`.
    private func scheduleFocusRefresh() {
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshStatus() } }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func statusChanged() {
        syncLiveBranch()
        render()
    }

    /// `resolveLiveThreadBranchUpdate` (logic.ts:483-512): a draft in the project checkout follows the
    /// checkout's ref when it changes outside the app.
    private func syncLiveBranch() {
        guard let target, target.isDraft, running == nil, let status,
              !(target.envMode == .worktree && target.worktreePath == nil) else { return }
        if status.refName == nil && target.branch != nil { return }
        if target.branch == status.refName { return }
        if let threadBranch = target.branch, let ref = status.refName,
           !BranchToolbarLogic.isTemporaryWorktreeBranch(threadBranch), BranchToolbarLogic.isTemporaryWorktreeBranch(ref) { return }
        composer.updateDraft { $0.branch = status.refName }
    }

    // MARK: Refs

    private func loadRefs() {
        guard let target, let shell else { return }
        let key = statusKey
        refsKey = key
        Task { [weak self] in
            let value = try? await shell.supervisor.request(VcsRPC.listRefs, payload: VcsRPC.listRefsInput(cwd: target.cwd))
            guard let self, self.refsKey == key else { return }
            self.refs = (try? value?.decode(as: VcsListRefsResult.self))?.refs ?? []
            self.refsLoaded = true
            self.seedWorktreeBase()
            self.render()
        }
    }

    /// The worktree base defaults to the repository's default branch, else the checked-out one
    /// (BranchToolbarBranchSelector.tsx:529-554).
    private func seedWorktreeBase() {
        guard let target, target.isDraft, target.envMode == .worktree, target.worktreePath == nil, target.branch == nil, refsLoaded,
              let base = refs.first(where: \.isDefault)?.name ?? currentGitBranch else { return }
        composer.updateDraft { $0.branch = base }
    }

    private var currentGitBranch: String? { status?.refName ?? refs.first(where: \.current)?.name }

    /// `resolveBranchToolbarValue`, with a pending switch shown at once (`useOptimistic`).
    private var resolvedBranch: String? {
        guard let target else { return nil }
        return optimisticBranch ?? BranchToolbarLogic.toolbarValue(mode: target.envMode, worktreePath: target.worktreePath,
                                                                    threadBranch: target.branch, currentGitBranch: currentGitBranch)
    }

    private var forceNewWorktree: Bool { composer.currentDraft != nil && composer.pickers.currentMultiple != nil }

    private var isSelectingWorktreeBase: Bool {
        guard let target else { return false }
        return target.envMode == .worktree && target.worktreePath == nil && target.isDraft
    }

    private var branchLabel: String {
        guard let target else { return "Select ref" }
        let branch = resolvedBranch
        let remote = branch.flatMap { b in refs.first { $0.name == b } }.map { $0.isRemote == true }
        return BranchToolbarLogic.triggerLabel(worktreePath: target.worktreePath, mode: target.envMode, branch: branch,
                                               branchIsRemote: remote, startFromOrigin: target.startFromOrigin)
    }

    // MARK: Drawing

    private var isRepo: Bool { status?.isRepo ?? true } // assumed while loading, so no init flash
    private var isBusy: Bool { running != nil }

    private var environmentOption: (label: String, machine: String)? {
        guard let target else { return nil }
        let envs = sidebar?.state.environments ?? SidebarEnvironments()
        return (envs.labels[target.environmentId] ?? target.environmentId, envs.machine(target.environmentId))
    }

    private var previousWorktree: BranchToolbarLogic.PreviousWorktree? {
        guard let target, target.isDraft, let snapshot = sidebar?.snapshot else { return nil }
        let threads = snapshot.threads.filter { $0.projectId == target.projectId }.map {
            BranchToolbarLogic.ThreadWorkspace(branch: $0.branch, worktreePath: $0.worktreePath,
                                               updatedAt: $0.updatedAt.epochMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                                               archived: $0.archivedAt != nil)
        }
        return BranchToolbarLogic.previousWorktree(threads, currentWorktreePath: target.worktreePath)
    }

    private func folderIcon(_ target: Target) -> IconDefinition {
        if target.envMode == .worktree { return IconName.folderGit2.definition }
        return (target.worktreePath != nil ? IconName.folderGit : IconName.folder).definition
    }

    private var runOnChoices: Bool { panel.contextStrip.runOn.options.count > 1 }

    /// After each render (the card's Open in row follows the target).
    var onRender: (() -> Void)?

    private func render() {
        panel.proactiveRepositoryIsGit = status?.isRepo
        defer { onRender?() }
        composer.draftIsGitRepo = target?.isDraft == true && isRepo
        guard let target else {
            panel.detailsCard.showsVersionControl = false
            return
        }
        if !target.isDraft {
            panel.contextStrip.showsGitControls = isRepo
            panel.showsContextStrip = isRepo || target.environmentId != sidebar?.state.environments.primaryId
            let runOn = panel.contextStrip.runOn
            runOn.options = [RunOnOption(environmentId: target.environmentId, label: environmentOption?.label ?? target.environmentId, machine: environmentOption?.machine ?? "")]
            runOn.selectedId = target.environmentId
            runOn.locked = true
            runOn.autoBalanceLabel = nil
            runOn.offersAutoBalance = false
        }
        let modeLocked = !target.isDraft
        let label = BranchToolbarLogic.workspaceLabel(mode: target.envMode, worktreePath: target.worktreePath, modeLocked: modeLocked)
        let env = environmentOption

        // The composer strip (drafts only): the machine shows when it can be picked or isn't this one.
        let strip = panel.contextStrip
        let indicator = runOnChoices || (env != nil && target.environmentId != environments.primaryId)
        strip.runContext.glyphs = indicator ? [EnvironmentMachineIcon.definition(env?.machine ?? "server"), folderIcon(target)] : [folderIcon(target)]
        strip.runContext.text = strip.runOn.autoBalanceLabel ?? (indicator ? env?.label ?? "Run on" : label)
        strip.runContext.tooltipText = label
        strip.runContext.interactive = target.isDraft && composer.currentDraft != nil
        strip.branch.text = branchLabel
        strip.branch.isEnabled = refsLoaded && !branchActionPending

        // The details card.
        let card = panel.detailsCard
        card.runContext.icons = env != nil ? [EnvironmentMachineIcon.definition(env!.machine), folderIcon(target)] : [folderIcon(target)]
        card.runContext.text = env?.label ?? label
        card.runContext.kind = target.isDraft && runOnChoices || target.isDraft ? .select : .locked
        card.runContext.tooltipText = (target.envMode == .worktree && target.worktreePath == nil) ? label : target.cwd
        card.branch.text = branchLabel
        card.branch.isEnabled = refsLoaded && !branchActionPending
        card.showsVersionControl = true
        card.isRepo = isRepo
        renderGitActions()
        let totals = status?.branchChanges.map { ($0.insertions, $0.deletions) } ?? status.map { ($0.workingTree.insertions, $0.workingTree.deletions) } ?? (0, 0)
        card.totals.insertions = totals.0
        card.totals.deletions = totals.1
        panel.needsLayout = true
    }

    private var quickAction: GitActionsLogic.QuickAction {
        GitActionsLogic.quickAction(status, busy: isBusy, isDefaultRef: status?.isDefaultRef ?? false, hasPrimaryRemote: status?.hasPrimaryRemote ?? false)
    }

    private var terminology: ChangeRequestTerminology { ChangeRequestTerminology.of(status?.sourceControlProvider) }

    /// `SourceControlIcon`: the host's glyph, GitHub's by default.
    private var providerIcon: IconName {
        switch status?.sourceControlProvider?.kind {
        case nil, "github": .brandGitHub
        case "gitlab": .brandGitLab
        case "forgejo": .brandForgejo
        default: .gitPullRequestArrow
        }
    }

    /// `GitQuickActionIcon`.
    private func quickIcon(_ q: GitActionsLogic.QuickAction) -> IconName {
        switch q.kind {
        case .openPublish: return .cloudUpload
        case .runPull: return .cloudDownload
        case .runAction:
            if q.action == .commit { return .gitCommitHorizontal }
            if q.action == .push || q.action == .commitPush { return .cloudUpload }
            return providerIcon
        case .showHint:
            if q.label == "Commit" { return .gitCommitHorizontal }
            if q.label == "Push" { return .cloudUpload }
            return .info
        }
    }

    private func renderGitActions() {
        let split = panel.detailsCard.gitActions
        let key = statusKey ?? ""
        if let running {
            let status = GitActionsLogic.progressStatus(isPull: running.isPull, currentLabel: running.label)
            let output = running.isPull ? nil : running.output?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            split.primary.mode = .running(status: status, output: output)
            let started = running.isPull ? running.startedAt : running.hookStartedAt ?? running.startedAt
            split.elapsedText = GitActionsLogic.elapsed(Date().timeIntervalSince(started))
            split.primary.looksDisabled = false
            split.primary.isEnabled = false
            return
        }
        split.elapsedText = nil
        if let success, success.key == key {
            split.primary.mode = .success(title: success.title, description: success.description)
            split.primary.isEnabled = false
            split.primary.looksDisabled = false
            return
        }
        let q = quickAction
        split.primary.mode = .idle
        split.primary.icon = quickIcon(q).definition
        split.primary.text = q.label
        split.primary.isEnabled = true
        split.primary.looksDisabled = q.disabled
        split.primary.toolTip = q.disabled ? q.hint ?? "This action is currently unavailable." : nil
        split.secondary.isEnabled = true
    }

    // MARK: Details card

    private func toggleDetails() {
        let open = !panel.detailsOpen
        panel.setDetailsOpen(open)
        UserDefaults.standard.set(open, forKey: Self.detailsOpenKey)
        if open { refreshStatus() }
    }

    // MARK: Run context menu

    /// `RunContextSelector`'s menu: "Run on" (with a choice of machines) and "Workspace": the checkout, a new
    /// worktree, and the previous worktree when there is one.
    private func openRunContextMenu(inPanel: Bool) {
        guard let target, target.isDraft, composer.currentDraft != nil else { return }
        let anchor: NSView = inPanel ? panel.detailsCard.runContext : panel.contextStrip.runContext
        var items: [MenuItem] = []
        let runOn = panel.contextStrip.runOn
        if runOn.options.count > 1 {
            items.append(.label("Run on"))
            if let item = runOn.autoBalanceMenuItem() { items.append(item) }
            for option in runOn.options {
                var item = MenuItem.radio(option.label, checked: runOn.autoBalanceLabel == nil && option.environmentId == runOn.selectedId)
                item.glyph = EnvironmentMachineIcon.definition(option.machine)
                item.closesOnClick = true
                item.action = { [weak runOn] in if option.environmentId != runOn?.selectedId || runOn?.autoBalanceLabel != nil { runOn?.onChange?(option.environmentId) } }
                items.append(item)
            }
            items.append(.separator)
        }
        items.append(.label("Workspace"))
        var local = MenuItem.radio(BranchToolbarLogic.currentWorkspaceLabel(target.worktreePath), checked: target.envMode == .local)
        local.glyph = (target.worktreePath != nil ? IconName.folderGit : IconName.folder).definition
        local.isDisabled = forceNewWorktree
        local.closesOnClick = true
        local.action = { [weak self] in self?.setEnvMode(.local) }
        items.append(local)
        var worktree = MenuItem.radio(BranchToolbarLogic.envModeLabel(.worktree), checked: target.envMode == .worktree)
        worktree.glyph = IconName.folderGit2.definition
        worktree.closesOnClick = true
        worktree.action = { [weak self] in self?.setEnvMode(.worktree) }
        items.append(worktree)
        if !forceNewWorktree, let previous = previousWorktree {
            var item = MenuItem.radio("Previous worktree", checked: false)
            item.glyph = IconName.history.definition
            item.subtitle = previous.branch
            item.closesOnClick = true
            item.action = { [weak self] in self?.usePreviousWorktree() }
            items.append(item)
        }
        let width: CGFloat = inPanel ? anchor.bounds.width : previousWorktree != nil ? 336 : 0
        let placement = inPanel ? PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none)
            : PopupPlacement(side: .top, align: .start, sideOffset: 4, fallbackAxisSide: .none)
        MenuPopupView.show(items, from: anchor, placement: placement, minimumWidth: width)
    }

    /// `onEnvModeChange` for a draft (ChatView.tsx:10791-10822): a new worktree leaves any picked worktree.
    /// Start from origin follows the project's `newWorktreesStartFromOrigin` (`resolveNewDraftStartFromOrigin`).
    private func setEnvMode(_ mode: EnvMode) {
        guard !forceNewWorktree else { return }
        let fromOrigin = mode == .worktree && composer.newWorktreesStartFromOrigin
        composer.updateDraft { d in
            d.envMode = mode
            d.startFromOrigin = fromOrigin
            if mode == .worktree, d.worktreePath != nil { d.worktreePath = nil }
        }
        refresh()
        seedWorktreeBase()
        composer.focusComposer()
    }

    /// `onUsePreviousWorktree`: the draft points at the newest other worktree of the project.
    func usePreviousWorktree() {
        guard !forceNewWorktree else { return }
        guard let previous = previousWorktree else { return }
        composer.updateDraft { d in
            d.branch = previous.branch
            d.worktreePath = previous.worktreePath
            d.envMode = .worktree
        }
        refresh()
    }

    // MARK: Branch picker

    func openBranchPicker(inPanel: Bool) {
        guard let target, refsLoaded, !branchActionPending, picker == nil else { return }
        let anchor: NSView = inPanel ? panel.detailsCard.branch : panel.contextStrip.branch
        let view = BranchPickerView()
        view.width = inPanel ? anchor.bounds.width : 320
        view.selectedValue = resolvedBranch
        view.startFromOrigin = isSelectingWorktreeBase ? target.startFromOrigin : nil
        view.onQuery = { [weak self] q in self?.pickerQuery(q) }
        view.onLoadMore = { [weak self] in self?.pickerLoadMore() }
        view.onStartFromOrigin = { [weak self] on in
            self?.composer.updateDraft { $0.startFromOrigin = on }
            self?.refresh()
        }
        view.onPick = { [weak self] value in self?.pick(value) }
        let placement = inPanel ? PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none)
            : PopupPlacement(side: .top, align: .end, sideOffset: 4, fallbackAxisSide: .none)
        guard let popup = view.present(from: anchor, placement: placement) else { return }
        popup.onClose = { [weak self] in self?.picker = nil }
        picker = (view, popup, "", [], inPanel)
        pickerQuery("")
    }

    private func pickerQuery(_ query: String) {
        guard picker != nil else { return }
        picker?.query = query
        picker?.pages = []
        fetchPickerPage(cursor: nil)
    }

    private func pickerLoadMore() {
        guard let p = picker, let cursor = p.pages.last?.nextCursor else { return }
        fetchPickerPage(cursor: cursor)
    }

    /// One `vcs.listRefs` page. The server filters by substring, so it gets the sanitized query
    /// (BranchToolbarBranchSelector.tsx:255-265).
    private func fetchPickerPage(cursor: Int?) {
        guard let target, let shell, let p = picker else { return }
        pickerSeq += 1
        let seq = pickerSeq
        let query = BranchToolbarLogic.sanitizeNewRefName(p.query)
        p.view.statusText = cursor == nil ? (p.pages.isEmpty ? "Loading refs..." : nil) : "Loading more refs..."
        Task { [weak self] in
            let value = try? await shell.supervisor.request(VcsRPC.listRefs, payload: VcsRPC.listRefsInput(cwd: target.cwd, query: query, cursor: cursor))
            guard let self, self.pickerSeq == seq, self.picker != nil else { return }
            if let page = try? value?.decode(as: VcsListRefsResult.self) { self.picker?.pages.append(page) }
            self.renderPicker()
        }
    }

    private func renderPicker() {
        guard let p = picker, let target else { return }
        var seen = Set<String>()
        let refs = p.pages.flatMap(\.refs).filter { seen.insert($0.name).inserted }
        let canCreate = !isSelectingWorktreeBase
        let items = BranchToolbarLogic.pickerItems(refs: refs, query: p.query, canCreate: canCreate)
        let byName = Dictionary(refs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // "Checkout pull request" first, on a local draft (BranchToolbarBranchSelector.tsx:286-312, 638-656).
        // ponytail: the row is one line with the reference as its badge; T3 draws the provider icon and a second line
        var checkout: [BranchPickerView.Row] = []
        if target.isDraft, let reference = ChangeRequestURL.reference(p.query.trimmingCharacters(in: .whitespacesAndNewlines)) {
            checkout = [BranchPickerView.Row(value: Self.checkoutPrefix + reference, title: "Checkout pull request", badge: reference, middleTruncates: false)]
        }
        p.view.rows = checkout + items.map { value in
            if value.hasPrefix(BranchToolbarLogic.createRefPrefix) {
                let name = BranchToolbarLogic.sanitizeNewRefName(String(value.dropFirst(BranchToolbarLogic.createRefPrefix.count)))
                return BranchPickerView.Row(value: value, title: "Create new ref \"\(name)\"", middleTruncates: false)
            }
            return BranchPickerView.Row(value: value, title: value, badge: byName[value].flatMap { BranchToolbarLogic.refBadge($0, projectCwd: target.projectRoot) })
        }
        let last = p.pages.last
        p.view.hasNextPage = last?.nextCursor != nil
        p.view.statusText = BranchToolbarLogic.statusText(loading: false, loadingMore: false, hasNextPage: last?.nextCursor != nil,
                                                          shown: refs.count, total: last?.totalCount ?? 0)
    }

    private func pick(_ value: String) {
        guard let p = picker else { return }
        let refs = p.pages.flatMap(\.refs)
        let query = p.query.trimmingCharacters(in: .whitespacesAndNewlines)
        closePicker()
        composer.focusComposer()
        if value.hasPrefix(Self.checkoutPrefix) {
            openPullRequestDialog(String(value.dropFirst(Self.checkoutPrefix.count)))
        } else if value.hasPrefix(BranchToolbarLogic.createRefPrefix) {
            createRef(query)
        } else if let ref = refs.first(where: { $0.name == value }) {
            selectBranch(ref)
        }
    }

    private func closePicker() {
        guard let p = picker, let window = panel.window else { picker = nil; return }
        PopupHost.host(for: window).close(p.popup, returnFocus: false)
        picker = nil
    }

    /// `selectBranch` (BranchToolbarBranchSelector.tsx:433-492).
    private func selectBranch(_ ref: VcsRef) {
        guard let target else { return }
        if isSelectingWorktreeBase {
            setThreadBranch(ref.name, worktreePath: nil)
            return
        }
        let selection = BranchToolbarLogic.selectionTarget(projectCwd: target.projectRoot, worktreePath: target.worktreePath, ref: ref)
        if selection.reuseExistingWorktree {
            setThreadBranch(ref.name, worktreePath: selection.nextWorktreePath)
            return
        }
        let name = ref.isRemote == true ? BranchToolbarLogic.localBranchName(fromRemote: ref.name) : ref.name
        runBranchAction(optimistic: name) { shell in
            let value = try await shell.supervisor.request(VcsRPC.switchRef, payload: VcsRPC.switchRefInput(cwd: selection.checkoutCwd, refName: ref.name))
            let switched = ref.isRemote == true ? value.objectValue?["refName"]?.stringValue ?? name : name
            return (switched, selection.nextWorktreePath)
        } failure: { "Failed to switch ref." }
    }

    /// `createRef` (BranchToolbarBranchSelector.tsx:494-525): creates the ref and checks it out.
    private func createRef(_ raw: String) {
        guard let target else { return }
        let name = BranchToolbarLogic.sanitizeNewRefName(raw)
        guard !name.isEmpty else { return }
        runBranchAction(optimistic: name) { shell in
            let value = try await shell.supervisor.request(VcsRPC.createRef, payload: VcsRPC.createRefInput(cwd: target.cwd, refName: name))
            return (value.objectValue?["refName"]?.stringValue ?? name, target.worktreePath)
        } failure: { "Failed to create and switch ref." }
    }

    private func runBranchAction(optimistic name: String, _ body: @escaping (ShellSession) async throws -> (String, String?),
                                 failure title: @escaping () -> String) {
        guard let shell else { return }
        optimisticBranch = name
        branchActionPending = true
        render()
        Task { [weak self] in
            do {
                let (branch, worktree) = try await body(shell)
                guard let self else { return }
                self.optimisticBranch = nil
                self.branchActionPending = false
                self.setThreadBranch(branch, worktreePath: worktree)
            } catch {
                guard let self else { return }
                self.optimisticBranch = nil
                self.branchActionPending = false
                self.toast(title(), Self.message(error), kind: .error)
            }
            self?.refreshStatus()
            self?.loadRefs()
            self?.render()
        }
    }

    /// `setThreadBranch`: a server thread gets `thread.metadata.update`; a draft stores the pick.
    // ponytail: T3 also stops a running session when the worktree changes; server threads with a worktree are locked here
    private func setThreadBranch(_ branch: String, worktreePath: String?) {
        guard let target else { return }
        if let threadId = target.threadId {
            guard let shell, target.branch != branch || target.worktreePath != worktreePath else { return }
            var command: [String: JSONValue] = ["type": .string("thread.metadata.update"), "commandId": .string(ThreadCommands.newCommandId()),
                                                "threadId": .string(threadId.localId.rawValue), "branch": .string(branch)]
            command["worktreePath"] = worktreePath.map(JSONValue.string) ?? .null
            Task { _ = try? await shell.supervisor.request("orchestration.dispatchCommand", payload: .object(command)) }
            return
        }
        composer.updateDraft { d in
            d.envMode = BranchToolbarLogic.envModeAfterBranchChange(nextWorktreePath: worktreePath, currentWorktreePath: target.worktreePath, mode: target.envMode)
            d.branch = branch
            d.worktreePath = worktreePath
        }
        refresh()
    }

    // MARK: Git actions

    private func openGitMenu() {
        refreshStatus()
        let split = panel.detailsCard.gitActions
        let status = self.status
        let hasRemote = status?.hasPrimaryRemote ?? false
        var items: [MenuItem] = GitActionsLogic.menuItems(status, busy: isBusy, hasPrimaryRemote: hasRemote).map { m in
            let icon: IconName = m.id == .commit ? .gitCommitHorizontal : m.id == .push ? .cloudUpload : providerIcon
            var item = MenuItem(m.label, icon: icon, disabled: m.disabled)
            item.tooltip = GitActionsLogic.disabledReason(m, status: status, busy: isBusy, hasPrimaryRemote: hasRemote)
            item.action = { [weak self] in self?.menuAction(m) }
            return item
        }
        if isRepo, status != nil, !hasRemote {
            var publish = MenuItem("Publish repository...", icon: .cloudUpload, disabled: isBusy)
            publish.action = { [weak self] in self?.openPublish() }
            items.append(publish)
        }
        items += GitActionsLogic.menuNotes(status).map { MenuItem.note($0) }
        guard !items.isEmpty else { return }
        // `anchor: panelAnchorRef`, `w-(--anchor-width)`: the whole split group.
        MenuPopupView.show(items, from: split.secondary, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none),
                           minimumWidth: split.bounds.width, anchorRect: split.convert(split.bounds, to: split.secondary))
    }

    /// `openDialogForMenuItem`: commit opens the dialog, push and create PR run at once.
    private func menuAction(_ item: GitActionsLogic.MenuItem) {
        guard !item.disabled else { return }
        if item.id == .commit { openCommitDialog() } else { runAction(item.action) }
    }

    /// `runQuickAction` (GitActionsControl.tsx:1514-1588).
    private func runQuickAction() {
        let q = quickAction
        if q.disabled {
            toast(q.label, q.hint, kind: .info)
            return
        }
        switch q.kind {
        case .openPublish: openPublish()
        case .runPull: pull()
        case .showHint: toast(q.label, q.hint, kind: .info)
        case .runAction: if let action = q.action { runAction(action) }
        }
    }

    private func openCommitDialog() {
        guard let window = panel.window, modal == nil else { return }
        let commit = CommitDialog(branch: status?.refName, isDefaultRef: status?.isDefaultRef ?? false,
                                  files: status?.workingTree.files, canChangeBranch: true, canWrite: true)
        let host = present(commit.dialog, in: window)
        commit.cancel.action = { [weak host] in host?.close() }
        commit.commit.action = { [weak self, weak host] in
            host?.close()
            self?.runAction(.commit, commitMessage: commit.commitMessage, filePaths: commit.selection.filePaths)
        }
        commit.commitOnNewBranch.action = { [weak self, weak host] in
            host?.close()
            self?.runAction(.commit, commitMessage: commit.commitMessage, featureBranch: true, filePaths: commit.selection.filePaths, skipDefaultPrompt: true)
        }
        commit.onOpenFile = { [weak self] path in
            guard let cwd = self?.target?.cwd else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path.hasPrefix("/") ? path : cwd + "/" + path))
        }
        window.makeFirstResponder(commit.message)
    }

    /// `runGitActionWithToast` (GitActionsControl.tsx:1322-1460): confirms on the default ref first, then streams
    /// `git.runStackedAction` and shows its progress in the split button.
    private func runAction(_ action: GitStackedAction, commitMessage: String? = nil, featureBranch: Bool = false,
                           filePaths: [String]? = nil, skipDefaultPrompt: Bool = false) {
        guard let target, let shell, running == nil else { return }
        let isDefault = featureBranch ? false : status?.isDefaultRef ?? false
        if !skipDefaultPrompt, GitActionsLogic.requiresDefaultBranchConfirmation(action, isDefaultRef: isDefault), let branch = status?.refName {
            confirmDefaultBranch(action, branch: branch, commitMessage: commitMessage, filePaths: filePaths)
            return
        }
        success = nil
        running = Running(isPull: false)
        startTicking()
        render()
        let payload = VcsRPC.runStackedActionInput(
            actionId: UUID().uuidString.lowercased(), cwd: target.cwd, action: action, commitMessage: commitMessage,
            featureBranch: featureBranch, filePaths: filePaths, threadId: target.threadId?.localId.rawValue,
            projectId: target.isDraft ? EnvironmentScope.localId(of: target.projectId.rawValue) : nil)
        let key = statusKey
        Task { [weak self] in
            var outcome: Result<GitRunStackedActionResult, Error> = .failure(GitActionError("The action ended without a result."))
            do {
                guard let (connection, _) = await shell.supervisor.waitForConnection(after: 0) else { throw CancellationError() }
                for try await value in await connection.stream(VcsRPC.runStackedAction, payload: payload) {
                    guard let event = GitActionProgressEvent(json: value) else { continue }
                    await MainActor.run { self?.progress(event) }
                    if case .finished(let result) = event { outcome = .success(result) }
                    if case .failed(let message) = event { outcome = .failure(GitActionError(message)) }
                }
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.running = nil
            self.stopTicking()
            switch outcome {
            case .success(let result):
                if let branch = GitActionsLogic.createdBranch(result) { self.setThreadBranch(branch, worktreePath: target.worktreePath) }
                self.showSuccess(result.toast.title, result.toast.description, key: key)
            case .failure(let error):
                self.toast("Action failed", Self.message(error), kind: .error)
            }
            self.refreshStatus()
            self.render()
        }
    }

    private func progress(_ event: GitActionProgressEvent) {
        guard var r = running else { return }
        switch event {
        case .started: r.startedAt = Date(); r.hookStartedAt = nil; r.output = nil
        case .phaseStarted(let label): r.label = label; r.phaseLabel = label; r.startedAt = Date(); r.hookStartedAt = nil; r.output = nil
        case .hookStarted(let name): r.label = "Running \(name)..."; r.hookStartedAt = Date(); r.output = nil
        case .hookOutput(let text): r.output = text
        case .hookFinished: r.label = r.phaseLabel; r.hookStartedAt = nil; r.output = nil
        case .finished, .failed: break
        }
        running = r
        render()
    }

    /// The default-branch dialog: continue here, or run it on a new feature branch.
    private func confirmDefaultBranch(_ action: GitStackedAction, branch: String, commitMessage: String?, filePaths: [String]?) {
        guard let window = panel.window, modal == nil else { return }
        let copy = GitActionsLogic.defaultBranchDialogCopy(action: action, branchName: branch,
                                                           includesCommit: GitActionsLogic.includesCommit(action, status: status, featureBranch: false),
                                                           terminology: terminology)
        let d = DefaultBranchDialog(copy: copy, canWrite: true, canChangeBranch: true)
        let host = present(d.dialog, in: window)
        d.abort.action = { [weak host] in host?.close() }
        d.proceed.action = { [weak self, weak host] in
            host?.close()
            self?.runAction(action, commitMessage: commitMessage, filePaths: filePaths, skipDefaultPrompt: true)
        }
        d.featureBranch.action = { [weak self, weak host] in
            host?.close()
            self?.runAction(action, commitMessage: commitMessage, featureBranch: true, filePaths: filePaths, skipDefaultPrompt: true)
        }
    }

    /// `vcs.pull` (fast-forward only).
    private func pull() {
        guard let target, let shell, running == nil else { return }
        success = nil
        running = Running(isPull: true)
        startTicking()
        render()
        let key = statusKey
        Task { [weak self] in
            do {
                let value = try await shell.supervisor.request(VcsRPC.pull, payload: VcsRPC.cwd(target.cwd))
                let result = try value.decode(as: VcsPullResult.self)
                let copy = GitActionsLogic.pullSuccess(result)
                self?.running = nil
                self?.showSuccess(copy.title, copy.description, key: key)
            } catch {
                self?.running = nil
                self?.toast("Pull failed", Self.message(error), kind: .error)
            }
            self?.stopTicking()
            self?.refreshStatus()
            self?.render()
        }
    }

    /// "Initialize Git" (`vcs.init`).
    private func initializeGit() {
        guard let target, let shell else { return }
        panel.detailsCard.initGit.text = "Initializing..."
        panel.detailsCard.initGit.isEnabled = false
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request(VcsRPC.initRepo, payload: VcsRPC.cwd(target.cwd))
            } catch {
                self?.toast("Git initialization failed", Self.message(error), kind: .error)
            }
            self?.panel.detailsCard.initGit.text = "Initialize Git"
            self?.panel.detailsCard.initGit.isEnabled = true
            self?.refreshStatus()
        }
    }

    /// The inline result in the split button for 10 s (`GIT_ACTION_SUCCESS_VISIBLE_MS`).
    private func showSuccess(_ title: String, _ description: String?, key: String?) {
        successWork?.cancel()
        success = (title, description, key ?? "")
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.success = nil; self?.render() } }
        successWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + GitActionsLogic.successVisibleSeconds, execute: work)
        render()
    }

    private func startTicking() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.renderGitActions() } }
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    // MARK: Publish

    private func openPublish() {
        guard let window = panel.window, modal == nil, let target, let shell else { return }
        Task { [weak self] in
            let value = try? await shell.supervisor.request(VcsRPC.discoverSourceControl)
            guard let self, self.modal == nil else { return }
            let wizard = PublishRepositoryDialog(discovered: value.map(SourceControlProviderDiscovery.list) ?? [], canWrite: true)
            let host = self.present(wizard.dialog, in: window)
            wizard.onClose = { [weak host] in host?.close() }
            // "Setup Required" closes the wizard and opens Settings > Source Control (`openSourceControlSettings`,
            // GitActionsControl.tsx:712-715).
            wizard.onOpenSettings = { [weak host, weak self] in host?.close(); self?.openSourceControlSettings?() }
            wizard.onOpenURL = { url in if let u = SafeExternalURL.parse(url) { NSWorkspace.shared.open(u) } }
            wizard.onPublish = { [weak self, weak wizard] provider, repository, visibility, remote, proto in
                let payload = VcsRPC.publishInput(cwd: target.cwd, provider: provider, repository: repository, visibility: visibility,
                                                  remoteName: remote, protocol: proto)
                Task {
                    do {
                        let result = try await shell.supervisor.request(VcsRPC.publishRepository, payload: payload)
                        wizard?.finish(try result.decode(as: SourceControlPublishResult.self))
                    } catch {
                        wizard?.fail(Self.message(error))
                    }
                    self?.refreshStatus()
                }
            }
        }
    }

    // MARK: Shortcuts

    /// `composer.branch`, `composer.workspace` and `composer.previousWorktree` act on the draft's strip
    /// (ChatView.tsx:8180-8222).
    func registerShortcuts(_ shortcuts: Shortcuts) {
        shortcuts.on("composer.branch") { [weak self] call in
            guard let self, self.stripShowsGit else { return false }
            if !call.isRepeat { self.openBranchPicker(inPanel: false) }
            return true
        }
        shortcuts.on("composer.workspace") { [weak self] call in
            guard let self, self.stripShowsGit else { return false }
            if !call.isRepeat { self.openRunContextMenu(inPanel: false) }
            return true
        }
        shortcuts.on("composer.previousWorktree") { [weak self] call in
            guard let self, self.stripShowsGit, self.previousWorktree != nil else { return false }
            if !call.isRepeat { self.usePreviousWorktree(); self.composer.focusComposer() }
            return true
        }
    }

    private var stripShowsGit: Bool { panel.window != nil && !panel.contextStrip.isHidden && panel.contextStrip.showsGitControls }

    // MARK: Checkout pull request (PullRequestThreadDialog.tsx)

    /// `openPullRequestDialog`: only on a local draft (`canCheckoutPullRequestIntoThread`, ChatView.tsx:2209).
    // ponytail: the source-control write and orchestration operate scopes are assumed granted; read them
    // from the session's scopes once the client tracks them
    func openPullRequestDialog(_ reference: String?) {
        guard modal == nil, let target, target.isDraft, let window = panel.window else { return }
        let dialog = PullRequestThreadDialog(initialReference: reference)
        let host = present(dialog.dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil; self?.checkoutDialog = nil; self?.resolveTask?.cancel() }
        checkoutDialog = dialog
        dialog.cancel.action = { host.close() }
        dialog.onReference = { [weak self] ref in self?.resolveCheckout(ref, debounce: true) }
        dialog.onConfirm = { [weak self, weak dialog] mode, ref in
            guard let self, let dialog else { return }
            self.prepareCheckout(dialog, mode: mode, reference: ref) { host.close() }
        }
        resolveCheckout(dialog.reference, debounce: false)
        DispatchQueue.main.async { window.makeFirstResponder(dialog.input) }
    }

    /// `usePullRequestResolution`: `git.resolvePullRequest` 450 ms after typing stops.
    private func resolveCheckout(_ reference: String?, debounce: Bool) {
        resolveTask?.cancel()
        guard let reference, let target, let shell, let dialog = checkoutDialog else { checkoutDialog?.resolving = false; return }
        dialog.resolving = true
        resolveTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(450)) }
            guard !Task.isCancelled else { return }
            do {
                let value = try await shell.supervisor.request("git.resolvePullRequest", payload: PullRequestPayloads.resolvePullRequest(cwd: target.projectRoot, reference: reference))
                let result = try value.decode(as: GitResolvePullRequestResult.self)
                guard !Task.isCancelled, let dialog = self?.checkoutDialog, dialog.reference == reference else { return }
                dialog.resolving = false
                dialog.resolved = result.pullRequest
            } catch {
                guard !Task.isCancelled, let dialog = self?.checkoutDialog, dialog.reference == reference else { return }
                dialog.resolving = false
                dialog.resolveError = Self.message(error)
            }
        }
    }

    /// `git.preparePullRequestThread`, then the draft takes the branch and worktree (`handlePreparedPullRequestThread`).
    private func prepareCheckout(_ dialog: PullRequestThreadDialog, mode: String, reference: String, done: @escaping () -> Void) {
        guard let target, let shell, let draft = composer.currentDraft,
              let payload = PullRequestPayloads.preparePullRequestThread(cwd: target.projectRoot, reference: reference, mode: mode,
                                                                          threadId: EnvironmentScope.localId(of: draft.threadId)) else { return }
        dialog.preparing = mode
        Task { [weak self] in
            do {
                let value = try await shell.supervisor.request("git.preparePullRequestThread", payload: payload)
                let result = try value.decode(as: GitPreparePullRequestThreadResult.self)
                guard let self else { return }
                dialog.preparing = nil
                self.composer.updateDraft { d in
                    d.branch = result.branch
                    d.worktreePath = result.worktreePath
                    d.envMode = result.worktreePath == nil ? .local : .worktree
                }
                self.refresh()
                done()
            } catch {
                dialog.preparing = nil
                dialog.prepareError = Self.message(error)
            }
        }
    }

    // MARK: Helpers

    private func present(_ dialog: DialogView, in window: NSWindow) -> ModalHost {
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil }
        modal = host
        return host
    }

    private func toast(_ title: String, _ message: String?, kind: ToastQueue.Kind) {
        panel.toasts.show(ToastView(title: title, message: message, kind: kind))
    }

    nonisolated static func message(_ error: Error) -> String {
        if let e = error as? GitActionError { return e.message }
        if let e = error as? RPCClientError, let typed = e.typedError { return GitErrorText.message(typed) }
        if let e = error as? RPCClientError { return e.description }
        return "An error occurred."
    }

    struct GitActionError: Error { let message: String; init(_ m: String) { message = m } }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
