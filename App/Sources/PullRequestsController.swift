import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// What each environment says it can do with pull requests (`ExecutionEnvironmentCapabilities`):
/// `pullRequests`, `pullRequestChecks`, `threadPullRequests`, `threadPullRequestLinking`,
/// `threadPullRequestWatch`. Read once per session from the descriptor.
@MainActor
final class PullRequestCapabilities {
    private var descriptors: [String: EnvironmentDescriptor] = [:]
    private var pending: Set<String> = []
    private let environments: Environments
    var onChange: (() -> Void)?

    init(environments: Environments) { self.environments = environments }

    func has(_ environmentId: String?, _ name: String) -> Bool {
        guard let environmentId else { return false }
        guard let d = descriptors[environmentId] else { load(environmentId); return false }
        return d.capability(name)
    }

    func known(_ environmentId: String) -> Bool { descriptors[environmentId] != nil }

    func load(_ environmentId: String) {
        guard !pending.contains(environmentId), let http = environments.session(environmentId)?.http else { return }
        pending.insert(environmentId)
        Task { [weak self] in
            let d = try? await http.descriptor()
            guard let self else { return }
            self.pending.remove(environmentId)
            if let d { self.descriptors[environmentId] = d; self.onChange?() }
        }
    }

    func forget(_ environmentId: String) { descriptors[environmentId] = nil }
}

/// One pull request surface's reads and writes (PullRequestDetailPanel.tsx): `pullRequests.detail`,
/// then `pullRequests.activity`; the Code tab's `POST /api/pull-requests/diff` and
/// `pullRequests.filesViewed`; the actions, comments and reviews. Drives a `PullRequestDetailView`.
@MainActor
final class PullRequestDetailBinding {
    let view: PullRequestDetailView
    private let environments: Environments
    private let capabilities: PullRequestCapabilities
    var toast: (String, String?, ToastQueue.Kind) -> Void = { _, _, _ in }
    /// The state the surface's tab glyph wears, by surface id.
    var onStatus: ((String, PullRequestStateTone) -> Void)?
    /// A write landed; the list or the thread's status behind it may have moved.
    var onActed: ((String) -> Void)?
    private(set) var environmentId: String?
    private(set) var target: PullRequestSurfaceTarget?
    private(set) var detail: PullRequestDetail?
    private var generation = 0
    private var commit: String?
    private var patchKey: String?
    private var viewedStates: [String: String]?
    private var overlay: [String: Bool] = [:]
    private var pendingViewed: Set<String> = []
    /// The Code tab's slices (`sliceState`): patches in order and the cursor of the next one.
    private var slices: [String] = []
    private var sliceCursor: String?
    private var sliceLoading = false
    private var sliceError: String?
    /// The native stack read (`usePullRequestStack`).
    private var stackGeneration = 0

    init(view: PullRequestDetailView, environments: Environments, capabilities: PullRequestCapabilities) {
        self.view = view
        self.environments = environments
        self.capabilities = capabilities
        view.preferredMergeMethod = UserDefaults.standard.string(forKey: Self.mergeMethodKey) ?? "merge"
        view.onTab = { [weak self] tab in if tab == .code { self?.loadCode() } }
        view.onRetry = { [weak self] in self?.reload(invalidate: false) }
        view.onRefresh = { [weak self] in self?.reload(invalidate: true) }
        view.onOpenURL = { url in if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        view.onCopy = { [weak self] text, label in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.toast("\(label) copied", text, .success)
        }
        view.onMergeMethod = { m in UserDefaults.standard.set(m, forKey: Self.mergeMethodKey) }
        view.onAction = { [weak self] action, method in self?.perform(action, mergeMethod: method) }
        view.onComment = { [weak self] body in self?.comment(body) }
        view.onReview = { [weak self] verdict, body, comments in self?.review(verdict, body: body, comments: comments) }
        view.onCommit = { [weak self] oid in self?.commit = oid; self?.patchKey = nil; self?.loadCode() }
        view.onSetViewed = { [weak self] path, viewed in self?.setViewed(path, viewed) }
        view.onCheckout = { [weak self] _ in self?.toast("Check out is not in CandyWrapper yet", "Use the copied command from the header.", .info) }
        view.onCommentAction = { [weak self] body, action in self?.commentAction(body, action) }
        view.onSaveTitle = { [weak self] title in self?.update(title: title) }
        view.onSaveBody = { [weak self] body in self?.update(body: body) }
        view.onSaveComment = { [weak self] comment, body in self?.updateComment(comment, body) }
        view.onReact = { [weak self] subject, content, reacted, bar in self?.react(subject, content, reacted, bar) }
        view.onPickLabels = { [weak self] anchor in self?.openPicker(.labels, from: anchor) }
        view.onPickReviewers = { [weak self] anchor in self?.openPicker(.reviewers, from: anchor) }
        view.onLoadMoreDiff = { [weak self] in self?.loadNextSlice() }
        view.onStackAction = { [weak self] action in self?.runStackAction(action) }
        view.onStackRetry = { [weak self] in self?.loadStack() }
        view.reviewActions = PullRequestReviewThreadActions(
            reply: { [weak self] id, body, done in self?.write("pullRequests.replyToThread", { PullRequestPayloads.replyToThread($0, threadId: id, body: body) },
                                                               failure: "Reply could not be posted", done: done) },
            setResolved: { [weak self] id, resolved in self?.write("pullRequests.setThreadResolution", { PullRequestPayloads.setThreadResolution($0, threadId: id, resolved: resolved) },
                                                                    failure: "The conversation could not be updated", done: { _ in }) },
            loadMore: { [weak self] id, cursor, done in self?.loadThreadComments(id, cursor, done) },
            editComment: { [weak self] id, body, done in self?.write("pullRequests.updateComment", { PullRequestPayloads.updateComment($0, commentId: id, kind: "review-comment", body: body) },
                                                                     failure: "The comment could not be saved", done: done) },
            react: { [weak self] id, content, reacted, bar in self?.react(id, content, reacted, bar) })
    }

    /// `pullRequestMergeMethod` in T3's UI state store.
    static let mergeMethodKey = "pullRequests.mergeMethod"
    /// An environment's server settings, for the project's default merge method.
    nonisolated(unsafe) static var serverSettings: ((String) -> ServerSettingsValues?)?

    private var shell: ShellSession? { environments.session(environmentId) }

    var reference: PullRequestRef? {
        target.map { PullRequestRef(projectId: $0.projectId, host: capabilities.has(environmentId, "threadPullRequests") ? $0.host : nil,
                                    repository: $0.repository, number: $0.number) }
    }

    /// Shows a pull request; the same one again keeps what is loaded.
    func show(environmentId: String, target: PullRequestSurfaceTarget) {
        if self.environmentId == environmentId, self.target?.surfaceId == target.surfaceId { return }
        self.environmentId = environmentId
        self.target = target
        detail = nil
        commit = nil
        patchKey = nil
        viewedStates = nil
        overlay = [:]
        slices = []; sliceCursor = nil; sliceError = nil; sliceLoading = false
        view.tab = .summary
        view.currentMergeMethod = nil
        // `usePullRequestDefaultMergeMethodResolver`: the project's override over the environment's setting.
        view.projectDefaultMergeMethod = Self.serverSettings?(environmentId).flatMap {
            ProjectSettings.resolve($0, projectId: target.projectId).settings["pullRequestMergeMethod"].stringValue
        }
        view.showLoading(number: target.number)
        reload(invalidate: false)
    }

    func clear() {
        generation += 1
        environmentId = nil
        target = nil
        detail = nil
    }

    /// `refreshDetail`, or the header's Refresh (`refreshFromHost`, which invalidates the server's
    /// cache first with `pullRequests.invalidate`).
    func reload(invalidate: Bool) {
        guard let shell, let ref = reference, let target else { return }
        generation += 1
        let gen = generation
        view.refreshing = true
        Task { [weak self] in
            if invalidate { _ = try? await shell.supervisor.request("pullRequests.invalidate", payload: .object(["reference": ref.payload])) }
            do {
                let reply = try await shell.supervisor.request("pullRequests.detail", payload: ref.payload)
                let d = try reply.decode(as: PullRequestDetail.self)
                guard let self, self.generation == gen else { return }
                self.detail = d
                self.view.activityPending = true
                self.view.activityError = nil
                if let ref = self.reference { self.view.reviewKey = PullRequestReviewStore.key(ref) }
                self.view.show(d)
                self.loadStack()
                self.onStatus?(target.surfaceId, PullRequestStateTone(state: d.state, isDraft: d.isDraft))
                self.loadActivity(gen: gen)
                if self.view.tab == .code { self.patchKey = nil; self.loadCode() }
            } catch {
                guard let self, self.generation == gen else { return }
                self.view.refreshing = false
                let (title, message) = Self.failure(error, number: target.number)
                self.view.showFailure(title: title, message: message)
            }
        }
    }

    private func loadActivity(gen: Int) {
        guard let shell, let ref = reference else { return }
        Task { [weak self] in
            do {
                let reply = try await shell.supervisor.request("pullRequests.activity", payload: ref.payload)
                let activity = try reply.decode(as: PullRequestActivity.self)
                guard let self, self.generation == gen, var d = self.detail else { return }
                d.apply(activity)
                self.detail = d
                self.view.activityPending = false
                self.view.show(d)
            } catch {
                guard let self, self.generation == gen else { return }
                self.view.activityPending = false
                self.view.activityError = Self.failure(error, number: ref.number).1
            }
            self?.view.refreshing = false
        }
    }

    /// The Code tab: the first slice of the patch over HTTP (large payloads skip the socket) and the
    /// viewed marks; later slices follow `nextCursor` (PullRequestCodeTab.tsx:254-340, 620-640).
    private func loadCode() {
        guard let ref = reference, let d = detail, d.capabilities.diff else { return }
        let key = "\(ref.projectId):\(ref.repository):\(ref.number):\(commit ?? "all"):\(d.updatedAt)"
        guard patchKey != key else { return }
        patchKey = key
        slices = []; sliceCursor = nil; sliceError = nil
        view.setDiff(patches: [], loading: true, error: nil, commit: commit)
        fetchSlice(cursor: nil, key: key)
        loadViewed()
    }

    private func loadNextSlice() {
        guard let cursor = sliceCursor, !sliceLoading, let key = patchKey else { return }
        sliceError = nil
        fetchSlice(cursor: cursor, key: key)
    }

    private func fetchSlice(cursor: String?, key: String) {
        guard let shell, let ref = reference else { return }
        let commit = self.commit
        let gen = generation
        sliceLoading = true
        if cursor != nil { showSlices(loading: false, error: nil) }
        Task { [weak self] in
            do {
                let result = try await shell.http.post("api/pull-requests/diff", PullRequestPayloads.diff(ref, cursor: cursor, commit: commit), token: shell.token,
                                                       as: PullRequestDiffResult.self)
                guard let self, self.generation == gen, self.patchKey == key else { return }
                self.sliceLoading = false
                self.slices.append(result.patch)
                self.sliceCursor = result.nextCursor
                self.showSlices(loading: false, error: nil)
            } catch {
                guard let self, self.generation == gen, self.patchKey == key else { return }
                self.sliceLoading = false
                let message = Self.failure(error, number: ref.number).1
                if cursor == nil { self.showSlices(loading: false, error: message) } else { self.sliceError = message; self.showSlices(loading: false, error: nil) }
            }
        }
    }

    private func showSlices(loading: Bool, error: String?) {
        view.setDiff(patches: slices, loading: loading, error: error, nextCursor: sliceCursor, moreLoading: sliceLoading && !slices.isEmpty,
                     moreError: sliceError, commit: commit)
    }

    private func loadViewed() {
        guard let shell, let ref = reference, let store = detail?.capabilities.viewedFiles else {
            view.setViewed(states: nil, overlay: [:], store: nil)
            return
        }
        Task { [weak self] in
            let reply = try? await shell.supervisor.request("pullRequests.filesViewed", payload: ref.payload)
            let result = try? reply?.decode(as: PullRequestFilesViewedResult.self)
            guard let self else { return }
            if let result { self.viewedStates = Dictionary(result.files.map { ($0.path, $0.state) }, uniquingKeysWith: { _, b in b }) }
            self.overlay = PullRequestDetailLogic.settleOverlay(self.overlay, states: self.viewedStates, pending: self.pendingViewed, answered: [])
            self.view.setViewed(states: self.viewedStates, overlay: self.overlay, store: store)
        }
    }

    /// `pullRequests.setFilesViewed`: the press shows at once and is taken back if the host refuses.
    private func setViewed(_ path: String, _ viewed: Bool) {
        guard let shell, let ref = reference, let store = detail?.capabilities.viewedFiles else { return }
        overlay[path] = viewed
        pendingViewed.insert(path)
        view.setViewed(states: viewedStates, overlay: overlay, store: store)
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.setFilesViewed", payload: PullRequestPayloads.setFilesViewed(ref, files: [(path, viewed)]))
                self?.pendingViewed.remove(path)
                self?.loadViewed()
            } catch {
                guard let self else { return }
                self.pendingViewed.remove(path)
                self.overlay = PullRequestDetailLogic.revertOverlay(self.overlay, batch: [(path, viewed)], owned: [path])
                self.view.setViewed(states: self.viewedStates, overlay: self.overlay, store: store)
                self.toast("Could not save the viewed mark", Self.failure(error, number: ref.number).1, .error)
            }
        }
    }

    /// `pullRequests.runAction`, then a fresh read.
    func perform(_ action: String, mergeMethod: String?) {
        guard let shell, let ref = reference else { return }
        view.actionPending = true
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.runAction", payload: PullRequestPayloads.action(ref, action: action, mergeMethod: mergeMethod))
                guard let self else { return }
                self.view.actionPending = false
                self.toast(PullRequestDetailLogic.actionSuccess(action), nil, .success)
                self.onActed?(action)
                self.reload(invalidate: action == "update-branch" || action == "approve-workflows")
            } catch {
                guard let self else { return }
                self.view.actionPending = false
                self.toast(PullRequestDetailLogic.actionFailure(action), Self.failure(error, number: ref.number).1, .error)
            }
        }
    }

    private func comment(_ body: String) {
        guard let shell, let ref = reference, let payload = PullRequestPayloads.comment(ref, body: body) else { return }
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.comment", payload: payload)
                self?.view.composer?.commentPosted()
                self?.view.closeComposer()
                self?.reload(invalidate: false)
            } catch {
                self?.view.composer?.commentSubmitting = nil
                self?.toast("Could not post the comment", nil, .error)
            }
        }
    }

    /// `PullRequestReviewForm.submit`: the verdict, the summary and the pending line comments in one request.
    private func review(_ verdict: String, body: String, comments: [PullRequestReviewCommentDraft]) {
        guard let shell, let ref = reference else { return }
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.submitReview", payload: PullRequestPayloads.submitReview(ref, verdict: verdict, body: body, comments: comments))
                self?.view.composer?.reviewSubmitted(body: body, comments: comments)
                self?.view.closeComposer()
                self?.toast(PullRequestWriteLogic.verdicts.first { $0.value == verdict }?.sent ?? "Review submitted", nil, .success)
                self?.reload(invalidate: false)
            } catch {
                // The draft is kept.
                self?.view.composer?.reviewPending = false
                self?.toast("The review could not be submitted", nil, .error)
            }
        }
    }

    // MARK: WP7.5c writes

    /// One write RPC with its payload built from the reference; `done` says whether the host took it,
    /// then the detail reads again.
    private func write(_ method: String, _ build: (PullRequestRef) -> JSONValue?, failure: String, refresh: Bool = true,
                       done: @escaping @MainActor (Bool) -> Void) {
        guard let shell, let ref = reference, let payload = build(ref) else { done(false); return }
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request(method, payload: payload)
                done(true)
                if refresh { self?.reload(invalidate: false) }
            } catch {
                self?.toast(failure, Self.failure(error, number: ref.number).1, .error)
                done(false)
            }
        }
    }

    private func update(title: String) {
        view.titleSaving = true
        write("pullRequests.update", { PullRequestPayloads.update($0, title: title) }, failure: "The title could not be saved") { [weak self] ok in
            self?.view.titleSaving = false
            if ok { self?.view.cancelTitleEdit() }
        }
    }

    private func update(body: String) {
        view.bodySaving = true
        write("pullRequests.update", { PullRequestPayloads.update($0, body: body) }, failure: "Could not save the description") { [weak self] ok in
            self?.view.bodySaving = false
            if ok { self?.view.finishBodyEdit() }
        }
    }

    private func updateComment(_ comment: PullRequestComment, _ body: String) {
        guard comment.kind != "review" else { return }
        view.commentSaving = true
        write("pullRequests.updateComment", { PullRequestPayloads.updateComment($0, commentId: comment.id, kind: comment.kind, body: body) },
              failure: "Could not save the comment") { [weak self] ok in
            self?.view.commentSaving = false
            if ok { self?.view.finishCommentEdit() }
        }
    }

    /// `PullRequestReactionBar.toggle`: the pill already moved; a refusal takes it back.
    private func react(_ subject: String?, _ content: String, _ reacted: Bool, _ bar: PullRequestReactionBarView) {
        write("pullRequests.setReaction", { PullRequestPayloads.setReaction($0, subjectId: subject, content: content, reacted: reacted) },
              failure: "The reaction could not be saved") { [weak bar] ok in if !ok { bar?.pressFailed(content) } }
    }

    private func loadThreadComments(_ threadId: String, _ cursor: String, _ done: @escaping @MainActor (PullRequestThreadCommentsResult?) -> Void) {
        guard let shell, let ref = reference else { done(nil); return }
        Task { [weak self] in
            do {
                let value = try await shell.supervisor.request("pullRequests.threadComments", payload: PullRequestPayloads.threadComments(ref, threadId: threadId, cursor: cursor))
                done(try value.decode(as: PullRequestThreadCommentsResult.self))
            } catch {
                self?.toast("More comments could not be loaded", nil, .error)
                done(nil)
            }
        }
    }

    /// `performCommentAction`: post the comment, then close or reopen.
    private func commentAction(_ body: String, _ action: String) {
        guard let shell, let ref = reference, let payload = PullRequestPayloads.comment(ref, body: body) else { return }
        view.actionPending = true
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.comment", payload: payload)
            } catch {
                self?.view.actionPending = false
                self?.view.composer?.commentSubmitting = nil
                self?.toast("Could not post the comment", nil, .error)
                return
            }
            self?.view.composer?.commentPosted()
            self?.view.closeComposer()
            self?.perform(action, mergeMethod: nil)
        }
    }

    /// The label and reviewer pickers (PullRequestLabelPicker.tsx, PullRequestReviewerPicker.tsx): the
    /// candidates are read once it opens; each pick toggles one and the list is read again.
    private func openPicker(_ kind: PullRequestCandidatePickerView.Kind, from anchor: NSView) {
        guard let shell, let ref = reference else { return }
        let picker = PullRequestCandidatePickerView(kind: kind)
        var labels: [PullRequestLabelCandidate] = []
        var people: [PullRequestReviewerCandidate] = []
        var query = ""
        func render() {
            if kind == .labels {
                picker.rows = PullRequestWriteLogic.filterLabels(labels, query: query).map {
                    .init(key: $0.name, title: $0.name, detail: $0.description, dot: PullRequestListLogic.labelColor($0.color).flatMap(PullRequestStyle.hex),
                          checked: $0.isApplied)
                }
            } else {
                picker.rows = PullRequestWriteLogic.filterReviewers(people, query: query).map {
                    .init(key: "\($0.kind):\($0.id)", title: $0.login, actor: PullRequestActor(login: $0.login, name: $0.name, avatarUrl: $0.avatarUrl, isBot: $0.isBot),
                          trailing: $0.kind == "team" ? "team" : nil, checked: $0.isRequested)
                }
            }
        }
        func read() {
            Task {
                do {
                    if kind == .labels {
                        let list = try await shell.supervisor.request("pullRequests.labelCandidates", payload: ref.payload).decode(as: PullRequestLabelCandidateList.self)
                        labels = list.candidates; picker.truncated = list.truncated
                    } else {
                        let list = try await shell.supervisor.request("pullRequests.reviewerCandidates", payload: ref.payload).decode(as: PullRequestReviewerCandidateList.self)
                        people = list.candidates; picker.truncated = list.truncated
                    }
                    picker.state = .loaded
                    render()
                } catch {
                    picker.state = .failed(Self.failure(error, number: ref.number).1)
                }
            }
        }
        picker.onQuery = { q in query = q; render() }
        picker.onPick = { [weak self] key in
            guard let self else { return }
            picker.disabled = true
            if kind == .labels, let c = labels.first(where: { $0.name == key }) {
                self.write("pullRequests.setLabels", { PullRequestPayloads.setLabels($0, labels: [c.name], applied: !c.isApplied) },
                           failure: c.isApplied ? "Could not take \(c.name) off" : "Could not put \(c.name) on") { _ in picker.disabled = false; read() }
            } else if let c = people.first(where: { "\($0.kind):\($0.id)" == key }) {
                self.write("pullRequests.requestReviewers", { PullRequestPayloads.requestReviewers($0, reviewers: [(c.id, c.kind)], requested: !c.isRequested) },
                           failure: c.isRequested ? "Could not take back the review request to \(c.login)" : "Could not ask \(c.login) for a review") { [weak self] ok in
                    picker.disabled = false
                    if ok { self?.toast(c.isRequested ? "Review request to \(c.login) taken back" : "Review requested from \(c.login)", nil, .success) }
                    read()
                }
            }
        }
        picker.present(from: anchor)
        read()
    }

    // MARK: Stack

    /// `pullRequests.stack` once the detail says the host keeps stacks.
    private func loadStack() {
        guard let shell, let ref = reference, let d = detail, d.capabilities.stacks == true, capabilities.has(environmentId, "threadPullRequests") else {
            view.stack = nil
            view.allowsSingleMerge = true
            return
        }
        let supportsActions = d.capabilities.stackActions == true && capabilities.has(environmentId, "pullRequestStackActions")
        stackGeneration += 1
        let gen = stackGeneration
        view.stackFailed = false
        view.stackNotice = view.stack == nil ? nil : PullRequestWriteLogic.stackNotice(hasData: true, isSuccess: false, isPending: true, error: false)
        view.allowsSingleMerge = PullRequestWriteLogic.allowsSingleMerge(supportsStackActions: supportsActions, hasStack: view.stack != nil, stackPending: true, stackError: false)
        Task { [weak self] in
            do {
                let value = try await shell.supervisor.request("pullRequests.stack", payload: ref.payload)
                let stack = value == .null ? nil : try value.decode(as: PullRequestStackDetail.self)
                guard let self, self.stackGeneration == gen else { return }
                self.view.stack = stack
                self.view.stackNotice = nil
                self.view.stackCanMerge = supportsActions && PullRequestDetailLogic.can(d, "merge") && !PullRequestDetailLogic.allowedMergeMethods(d).isEmpty
                self.view.stackCanRebase = supportsActions && d.viewerPermissions.stackRebase == true
                self.view.allowsSingleMerge = PullRequestWriteLogic.allowsSingleMerge(supportsStackActions: supportsActions, hasStack: stack != nil, stackPending: false, stackError: false)
            } catch {
                guard let self, self.stackGeneration == gen else { return }
                self.view.stackFailed = true
                self.view.stackNotice = PullRequestWriteLogic.stackNotice(hasData: self.view.stack != nil, isSuccess: false, isPending: false, error: true)
                self.view.allowsSingleMerge = PullRequestWriteLogic.allowsSingleMerge(supportsStackActions: supportsActions, hasStack: self.view.stack != nil, stackPending: false, stackError: true)
            }
        }
    }

    /// "Merge stack" or "Rebase stack" (PullRequestStackMenu.tsx:76-124).
    private func runStackAction(_ action: String) {
        guard let shell, let ref = reference, let stack = view.stack, let d = detail else { return }
        let method = PullRequestDetailLogic.selectedMergeMethod(PullRequestDetailLogic.allowedMergeMethods(d), preferred: view.preferredMergeMethod)
        guard let payload = PullRequestWriteLogic.stackActionPayload(stack, ref: ref, action: action, mergeMethod: method) else { return }
        view.stackPending = true
        toast(action == "merge" ? "Merging stack..." : "Rebasing stack...", nil, .info)
        Task { [weak self] in
            do {
                _ = try await shell.supervisor.request("pullRequests.runAction", payload: payload)
                self?.toast(action == "merge" ? "Stack merge request completed" : "Stack rebased",
                            action == "merge" ? "GitHub merged the stack or added it to its merge queue." : nil, .success)
            } catch {
                self?.toast(action == "merge" ? "Could not merge the stack" : "Could not rebase the stack", Self.failure(error, number: ref.number).1, .error)
            }
            self?.view.stackPending = false
            self?.onActed?(action)
            self?.reload(invalidate: false)
        }
    }

    /// A failed read as the unavailable state's title and message (`PullRequestsUnavailableState`).
    nonisolated static func failure(_ error: Error, number: Int) -> (String, String) {
        if let e = error as? RPCClientError, let typed = e.typedError {
            if PullRequestErrors.isNotFound(tag: typed.tag, fields: typed.fields) {
                return ("Pull request #\(number) not found", "It may be an issue rather than a pull request, or this account can't see it.")
            }
            return ("Could not load pull requests", PullRequestErrors.message(tag: typed.tag, fields: typed.fields) ?? typed.message ?? typed.tag)
        }
        if case .status(_, let body?)? = error as? EnvironmentHTTPError {
            var fields: [String: JSONValue] = [:]
            if let r = body.reason { fields["reason"] = .string(r) }
            if let m = body.message { fields["detail"] = .string(m) }
            return ("Could not load pull requests", PullRequestErrors.message(tag: body.tag, fields: fields) ?? body.message ?? body.tag)
        }
        return ("Could not load pull requests", (error as? RPCClientError)?.description ?? "\(error)")
    }
}

/// The thread's pull requests: the right panel's `pull-request` and `pull-requests` tabs, the
/// "Link pull request" dialog, unlinking and watching, the copy shortcuts.
@MainActor
final class ThreadPullRequestsController {
    var openBrowserLink: ((URL) -> Bool)?
    var openIntegratedBrowser: ((URL) -> Void)?
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    let capabilities: PullRequestCapabilities
    private let detail: PullRequestDetailBinding
    /// The open thread (nil on a draft).
    var openThreadId: () -> ThreadId? = { nil }
    private var modal: ModalHost?
    /// The open Link dialog; its fields talk to it weakly, so it is held here while it shows.
    private var linkDialog: LinkPullRequestDialog?
    // ponytail: preview details are cached for the session with no eviction; bound it if long sessions grow
    fileprivate var previewCache: [String: PullRequestDetail] = [:]
    fileprivate weak var previewAnchor: NSView?
    fileprivate var previewPopup: OpenPopup?

    init(panel: ThreadPanelView, sidebar: SidebarContentView, environments: Environments, capabilities: PullRequestCapabilities) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        self.capabilities = capabilities
        detail = PullRequestDetailBinding(view: panel.pullRequestView, environments: environments, capabilities: capabilities)
        detail.toast = { [weak panel] title, message, kind in panel?.toasts.show(ToastView(title: title, message: message, kind: kind)) }
        detail.onStatus = { [weak self] id, tone in self?.panel.pullRequestStatus[id] = tone }
        panel.pullRequestView.context = .thread
        panel.pullRequestView.onLinkThread = { [weak self] in self?.toggleLinkFromPanel() }
        panel.onAddPullRequest = { [weak self] in self?.openCurrentPullRequest() }
        let list = panel.linkedPullRequestsView
        list.onOpen = { [weak self] link in self?.open(link) }
        list.onLink = { [weak self] in self?.openLinkDialog() }
        list.onUnlink = { [weak self] link in self?.unlink(link) }
        list.onCopy = { [weak self] url in self?.copy(url, title: "Link copied") }
        list.onOpenExternal = { url in if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        list.onWatch = { [weak self] link, watching in self?.watch(link, watching) }
        MarkdownView.linkHandler = self
    }

    fileprivate var thread: ThreadShell? {
        guard let id = openThreadId() else { return nil }
        return sidebar?.snapshot?.threads.first { $0.id == id }
    }

    private var project: ProjectShell? {
        guard let thread else { return nil }
        return sidebar?.snapshot?.projects.first { $0.id == thread.projectId }
    }

    /// The panel changed, the thread changed or its shell moved: availability, tab glyphs and the
    /// active surface's content.
    func sync() {
        guard let thread, let env = thread.id.environmentId else {
            panel.pullRequestAvailable = false
            panel.pullRequestsAvailable = false
            if cardKey != nil { cardKey = nil; panel.detailsCard.pullRequestRows = [] }
            detail.clear()
            return
        }
        let links = thread.pullRequests ?? []
        panel.pullRequestsAvailable = capabilities.has(env, "threadPullRequests") && !ThreadPullRequests.visible(links).isEmpty
        panel.pullRequestAvailable = capabilities.has(env, "pullRequests") && panelTarget(thread) != nil
        // Linked snapshots seed the tab glyphs (`resolvePullRequestTabLink`).
        var status = panel.pullRequestStatus
        for surface in panel.panelState.surfaces {
            guard let t = surface.pullRequest else { continue }
            if let link = links.first(where: { $0.number == t.number && $0.repository.lowercased() == t.repository.lowercased() }), let s = link.snapshot {
                status[surface.id] = PullRequestStateTone(state: s.state.rawValue, isDraft: s.isDraft)
            }
        }
        panel.pullRequestStatus = status
        updateCardRows(thread)
        guard panel.panelState.isOpen, let active = panel.panelState.active else { return }
        switch active {
        case .pullRequest(let target):
            let linked = links.contains { $0.number == target.number && $0.repository.lowercased() == target.repository.lowercased() }
            panel.pullRequestView.linkItemTitle = capabilities.has(env, "threadPullRequests") ? (linked ? "Unlink from this thread" : "Link to this thread") : nil
            detail.show(environmentId: target.environmentId ?? env, target: target)
        case .pullRequests:
            panel.linkedPullRequestsView.onWatch = capabilities.has(env, "threadPullRequestWatch") ? { [weak self] link, w in self?.watch(link, w) } : nil
            panel.linkedPullRequestsView.set(links, nowMs: TimestampFormat.nowMs())
        default:
            break
        }
    }

    /// Threads whose details card lists every link (`Show N more`).
    private var expandedCards: Set<ThreadId> = []
    private var cardKey: String?

    /// The details card's pull request rows (ThreadDetailsPrRows.tsx, ThreadDetailsPrRow.tsx): the
    /// current link as "#n: title" in its state's glyph and tone, then the rest of the thread's links
    /// while expanded. Each opens its pull request in the right panel.
    /// A watched link's eye stops the watch (ThreadDetailsPrRows.tsx:77-93); the server ends a watch
    /// when the pull request closes, so only an open one shows it.
    // ponytail: rows show the linked snapshot only; T3 reads the detail and checks for the second line
    // (checks, Resolve/Ready/Fix/Merge). Add it when a server here can read a host
    private func updateCardRows(_ thread: ThreadShell) {
        let links = ThreadPullRequests.visible(thread.pullRequests ?? [])
        let current = ThreadPullRequests.current(links)
        let expanded = expandedCards.contains(thread.id)
        // The capability can arrive after the first rows.
        let canWatch = thread.id.environmentId.map { capabilities.has($0, "threadPullRequestWatch") } ?? false
        let key = "\(thread.id.rawValue)|\(expanded)|" + links.map { "\($0.key.id):\($0.snapshot?.state.rawValue ?? "-"):\($0.snapshot?.isDraft == true):\($0.snapshot?.title ?? ""):\($0.watch != nil)" }.joined(separator: ",")
            + "|\(thread.linkedPullRequest?.url ?? "")|\(canWatch)"
        guard key != cardKey else { return }
        cardKey = key
        func row(number: Int, title: String?, state: PullRequestState?, isDraft: Bool, link: ThreadPullRequestLink? = nil,
                 open: @escaping @MainActor @Sendable () -> Void) -> DetailsRowControl {
            let r = DetailsRowControl(kind: .row)
            if let link, canWatch, link.watch != nil, (state ?? .open) == .open {
                let eye = PullRequestWatchToggle(number: number)
                eye.action = { [weak self] in self?.watch(link, false) }
                r.trailing = eye
            }
            let tone = state.map { PullRequestStateTone(state: $0.rawValue, isDraft: isDraft) }
            r.icons = [(tone.map(PullRequestStyle.icon) ?? .gitPullRequestArrow).definition]
            r.iconColor = tone.map(PullRequestStyle.color)
            r.text = "#\(number)" + (title.map { ": \($0)" } ?? "")
            r.setAccessibilityLabel(r.text)
            r.action = open
            return r
        }
        var rows: [DetailsRowControl] = []
        if let current {
            rows.append(row(number: current.number, title: current.snapshot?.title, state: current.snapshot?.state, isDraft: current.snapshot?.isDraft ?? false, link: current) { [weak self] in self?.open(current) })
            let rest = ThreadPullRequests.lines(links).map(\.link).filter { $0.key.id != current.key.id }
            if !rest.isEmpty {
                if expanded {
                    for link in rest {
                        rows.append(row(number: link.number, title: link.snapshot?.title, state: link.snapshot?.state, isDraft: link.snapshot?.isDraft ?? false, link: link) { [weak self] in self?.open(link) })
                    }
                }
                let toggle = DetailsRowControl(kind: .row)
                toggle.icons = [(expanded ? IconName.minus : .plus).definition]
                toggle.text = expanded ? "Show less" : "Show \(rest.count) more"
                toggle.action = { [weak self] in
                    guard let self else { return }
                    if self.expandedCards.contains(thread.id) { self.expandedCards.remove(thread.id) } else { self.expandedCards.insert(thread.id) }
                    self.sync()
                }
                rows.append(toggle)
            }
        } else if let legacy = thread.linkedPullRequest {
            rows.append(row(number: legacy.number, title: nil, state: nil, isDraft: false) { [weak self] in self?.openCurrentPullRequest() })
        }
        panel.detailsCard.pullRequestRows = rows
    }

    /// `threadPullRequestPanelTarget`: the current link, else the legacy link or the branch's PR.
    private func panelTarget(_ thread: ThreadShell) -> PullRequestSurfaceTarget? {
        let projectId = thread.projectId.localId.rawValue
        if let current = ThreadPullRequests.current(thread.pullRequests ?? []) {
            let projectForLink = ChangeRequestURL.parse(current.url).flatMap { link in
                sidebar?.snapshot?.projects.first { $0.id.environmentId == thread.id.environmentId && $0.repositoryIdentity?.owns(link) == true }
            }
            return PullRequestSurfaceTarget(projectId: projectForLink?.id.localId.rawValue ?? projectId, host: current.host,
                                            repository: current.repository, number: current.number, url: current.url)
        }
        if let legacy = thread.linkedPullRequest ?? thread.branchPullRequest {
            return PullRequestSurfaceTarget(projectId: legacy.projectId.rawValue, repository: legacy.repository, number: legacy.number, url: legacy.url)
        }
        return nil
    }

    /// "Pull request" from the + menu: the thread's current pull request.
    func openCurrentPullRequest() {
        guard let thread, let target = panelTarget(thread) else { return }
        panel.mutatePanel { $0.openPullRequest(target); return [] }
    }

    /// A linked pull request clicked: the panel when a project here reads its repository
    /// (`useOpenChangeRequestLink`), the browser otherwise.
    func open(_ link: ThreadPullRequestLink) {
        guard let thread, let env = thread.id.environmentId, capabilities.has(env, "pullRequests"),
              let parsed = ChangeRequestURL.parse(link.url) else {
            if let u = URL(string: link.url) { NSWorkspace.shared.open(u) }
            return
        }
        let projects = (sidebar?.snapshot?.projects ?? []).filter { $0.id.environmentId == env }
        let project = projects.first { $0.repositoryIdentity?.owns(parsed) == true }
            ?? projects.first { $0.repositoryIdentity?.pullRequestHost == parsed.host }
            ?? self.project
        guard let project else { if let u = URL(string: link.url) { NSWorkspace.shared.open(u) }; return }
        panel.mutatePanel {
            $0.openPullRequest(PullRequestSurfaceTarget(projectId: project.id.localId.rawValue, host: link.host, repository: link.repository,
                                                        number: link.number, url: link.url))
            return []
        }
    }

    /// The URL of the pull request the panel shows, for `thread.copyReference`.
    var openPanelPullRequestURL: String? {
        guard panel.panelState.isOpen, let target = panel.panelState.active?.pullRequest else { return nil }
        return detail.detail?.url ?? target.url
    }

    /// `resolveThreadReferenceCopyTarget` (shared/threadReference.ts:13-40).
    func copyReferenceTarget(threadId: String) -> (value: String, title: String) {
        let url = openPanelPullRequestURL ?? ThreadPullRequests.current(thread?.pullRequests ?? [])?.url ?? thread?.linkedPullRequest?.url
        return url.map { ($0, "PR link copied") } ?? (threadId, "Thread ID copied")
    }

    /// `pullRequest.copyNumber` while a pull request tab is active (PullRequestDetailPanel.tsx:745-760).
    func copyNumber() -> Bool {
        guard panel.window != nil, panel.panelState.isOpen, let target = panel.panelState.active?.pullRequest else { return false }
        copy("#\(target.number)", title: "PR number copied")
        return true
    }

    // MARK: Linking

    /// The detail's ⋯ "Link to this thread" / "Unlink from this thread".
    private func toggleLinkFromPanel() {
        guard let thread, let target = panel.panelState.active?.pullRequest, let d = detail.detail else { return }
        if let link = (thread.pullRequests ?? []).first(where: { $0.number == target.number && $0.repository.lowercased() == target.repository.lowercased() }) {
            unlink(link)
        } else if let parsed = ChangeRequestURL.parse(d.url) {
            change(thread: thread, resolved: LinkPullRequestLogic.Resolved(host: parsed.host, repository: parsed.repository, number: parsed.number, url: d.url), link: true) { _ in }
        }
    }

    /// "Link pull request to thread" (LinkPullRequestDialog.tsx).
    func openLinkDialog() {
        guard modal == nil, let thread, let env = thread.id.environmentId, let window = panel.window else { return }
        let multiple = capabilities.has(env, "threadPullRequests")
        guard multiple || capabilities.has(env, "threadPullRequestLinking") else {
            panel.toasts.show(ToastView(title: "Linking pull requests is not available on this server", kind: .error))
            return
        }
        var own: LinkPullRequestLogic.Project?
        if let identity = project?.repositoryIdentity, let host = identity.pullRequestHost,
           let repository = identity.displayName ?? identity.owner.flatMap({ o in identity.name.map { "\(o)/\($0)" } }) {
            own = LinkPullRequestLogic.Project(host: host, repository: repository, kind: identity.provider)
        }
        let projects = (sidebar?.snapshot?.projects ?? []).filter { $0.id.environmentId == env }
        // `canLinkChangeRequest`: any link in `multiple` mode, a matching project in `single`.
        let canLink: (ChangeRequestURL.Link) -> Bool = { link in multiple || projects.contains { $0.repositoryIdentity?.owns(link) == true } }
        let dialog = LinkPullRequestDialog(project: own, canLink: canLink)
        let host = ModalHost.present(dialog.dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil; self?.linkDialog = nil }
        linkDialog = dialog
        modal = host
        dialog.cancel.action = { host.close() }
        dialog.onSubmit = { [weak self, weak dialog] resolved in
            guard let self, let dialog else { return }
            dialog.pending = true
            self.change(thread: thread, resolved: resolved, link: true) { error in
                dialog.pending = false
                if let error { dialog.submitError = error } else { host.close() }
            }
        }
        DispatchQueue.main.async { window.makeFirstResponder(dialog.input) }
    }

    /// `changeLink` (usePullRequestLinking.ts:84-111) through the command the server advertises.
    fileprivate func change(thread: ThreadShell, resolved: LinkPullRequestLogic.Resolved, link: Bool, done: @escaping (String?) -> Void) {
        guard let env = thread.id.environmentId else { return }
        let key = ThreadPullRequestKey(host: resolved.host, repository: resolved.repository, number: resolved.number).normalized
        let threadId = thread.id.localId.rawValue
        let payload: JSONValue
        if capabilities.has(env, "threadPullRequests") {
            payload = link ? PullRequestPayloads.link(threadId: threadId, key: key, url: resolved.url) : PullRequestPayloads.unlink(threadId: threadId, key: key)
        } else {
            let parsed = ChangeRequestURL.parse(resolved.url)
            let legacy = parsed.flatMap { p in (sidebar?.snapshot?.projects ?? []).first { $0.id.environmentId == env && $0.repositoryIdentity?.owns(p) == true } }
            guard !link || legacy != nil else { done("The pull request is not available in this environment."); return }
            payload = PullRequestPayloads.legacyLink(threadId: threadId, projectId: link ? legacy?.id.localId.rawValue : nil,
                                                     repository: legacy?.repositoryIdentity?.pullRequestRepository ?? resolved.repository,
                                                     number: resolved.number, url: resolved.url)
        }
        Task { [weak self] in
            do {
                _ = try await self?.environments.dispatch(thread.id, payload)
                done(nil)
            } catch {
                done((error as? RPCClientError)?.description ?? "Could not link the pull request.")
            }
        }
    }

    func unlink(_ link: ThreadPullRequestLink) {
        guard let thread else { return }
        change(thread: thread, resolved: LinkPullRequestLogic.Resolved(host: link.host, repository: link.repository, number: link.number, url: link.url),
               link: false) { [weak self] error in
            if let error { self?.panel.toasts.show(ToastView(title: "Could not unlink the pull request", message: error, kind: .error)) }
        }
    }

    /// `thread.pull-request.watch`.
    private func watch(_ link: ThreadPullRequestLink, _ watching: Bool) {
        guard let thread else { return }
        let payload = JSONValue.object(["type": .string("thread.pull-request.watch"), "commandId": .string(ThreadCommands.newCommandId()),
                                        "threadId": .string(thread.id.localId.rawValue), "host": .string(link.host),
                                        "repository": .string(link.repository), "number": .number(Double(link.number)),
                                        "watching": .bool(watching)])
        Task { [weak self] in
            do { _ = try await self?.environments.dispatch(thread.id, payload) } catch {
                self?.panel.toasts.show(ToastView(title: watching ? "Could not watch the pull request" : "Could not stop watching", kind: .error))
            }
        }
    }

    private func copy(_ text: String, title: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        panel.toasts.show(ToastView(title: title, message: text, kind: .success))
    }

    func registerShortcuts(_ shortcuts: Shortcuts) {
        shortcuts.on("pullRequest.copyNumber") { [weak self] call in
            guard let self else { return false }
            if call.isRepeat { return self.panel.panelState.active?.pullRequest != nil }
            return self.copyNumber()
        }
    }
}

// MARK: - Links in Markdown (ChatMarkdown.tsx:2486-2530, 2955-3125; PullRequestLinkPreview.tsx)

extension ThreadPullRequestsController: MarkdownLinkHandler {
    /// `resolvePullRequestPreviewTarget` for the open thread's environment.
    private func previewTarget(_ url: URL) -> (env: String, ref: PullRequestRef)? {
        guard let thread, let env = thread.id.environmentId else { return nil }
        let projects = (sidebar?.snapshot?.projects ?? []).filter { $0.id.environmentId == env }.map { (id: $0.id.localId.rawValue, identity: $0.repositoryIdentity) }
        guard var ref = PullRequestWriteLogic.previewTarget(url: url.absoluteString, pullRequestsEnabled: capabilities.has(env, "pullRequests"), projects: projects) else { return nil }
        if !capabilities.has(env, "threadPullRequests") { ref.host = nil }
        return (env, ref)
    }

    func openLink(_ url: URL, from markdown: MarkdownView) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) || modifiers.contains(.control) { NSWorkspace.shared.open(url); return }
        // A pull request a project here reads opens in the panel (`useOpenChangeRequestLink`).
        if let target = previewTarget(url) {
            panel.mutatePanel {
                $0.openPullRequest(PullRequestSurfaceTarget(environmentId: target.env, projectId: target.ref.projectId, host: target.ref.host,
                                                            repository: target.ref.repository, number: target.ref.number, url: url.absoluteString))
                return []
            }
            return
        }
        if openBrowserLink?(url) != true { NSWorkspace.shared.open(url) }
    }

    /// `showExternalLinkContextMenu` with Link to thread or Unlink from thread for a pull request URL.
    func showLinkMenu(_ url: URL, event: NSEvent, in view: NSView, from markdown: MarkdownView) {
        let href = url.absoluteString
        var action: String?
        if let thread, let env = thread.id.environmentId, let parsed = ChangeRequestURL.parse(href) {
            let multiple = capabilities.has(env, "threadPullRequests")
            let linked = (thread.pullRequests ?? []).contains { $0.key.normalized == parsed.key.normalized }
                || thread.linkedPullRequest.map { $0.number == parsed.number && $0.repository.lowercased() == parsed.repository.lowercased() } == true
            let projects = (sidebar?.snapshot?.projects ?? []).filter { $0.id.environmentId == env }
            let canLink = (multiple || capabilities.has(env, "threadPullRequestLinking")) && (multiple || projects.contains { $0.repositoryIdentity?.owns(parsed) == true })
            action = linked ? "unlink-from-thread" : canLink ? "link-to-thread" : nil
        }
        let items: [MenuItem] = PullRequestWriteLogic.linkMenuItems(canOpenInPreview: panel.browserAvailable && openIntegratedBrowser != nil, threadLinkAction: action).map { entry in
            var item = MenuItem(entry.label)
            item.action = { [weak self] in self?.runLinkAction(entry.id, href: href) }
            return item
        }
        MenuPopupView.showContextMenu(items, in: view, at: view.convert(event.locationInWindow, from: nil))
    }

    private func runLinkAction(_ id: String, href: String) {
        switch id {
        case "open-in-preview": if let url = URL(string: href) { openIntegratedBrowser?(url) }
        case "open-external": if let u = URL(string: href) { NSWorkspace.shared.open(u) }
        case "copy-link":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(href, forType: .string)
        case "link-to-thread", "unlink-from-thread":
            guard let thread, let parsed = ChangeRequestURL.parse(href) else { return }
            let link = id == "link-to-thread"
            change(thread: thread, resolved: LinkPullRequestLogic.Resolved(host: parsed.host, repository: parsed.repository, number: parsed.number, url: href), link: link) { [weak self] error in
                if let error { self?.panel.toasts.show(ToastView(title: link ? "Unable to link pull request" : "Unable to unlink pull request", message: error, kind: .error)) }
            }
        default: break
        }
    }

    func previewsLink(_ url: URL, from markdown: MarkdownView) -> Bool { previewTarget(url) != nil }

    /// The card reads `pullRequests.detail` once it opens; a failed read shows nothing (the URL tooltip is T3's fallback).
    func showLinkPreview(_ url: URL, anchor: NSView, from markdown: MarkdownView) {
        guard let target = previewTarget(url) else { return }
        let key = "\(target.env) \(url.absoluteString)"
        previewAnchor = anchor
        if let d = previewCache[key] { previewPopup = PullRequestLinkPreviewView(detail: d, nowMs: TimestampFormat.nowMs()).present(over: anchor); return }
        Task { [weak self, weak anchor] in
            guard let self, let d = try? await self.environments.request(target.env, "pullRequests.detail", target.ref.payload).decode(as: PullRequestDetail.self) else { return }
            self.previewCache[key] = d
            guard let anchor, self.previewAnchor === anchor, anchor.window != nil else { return }
            self.previewPopup = PullRequestLinkPreviewView(detail: d, nowMs: TimestampFormat.nowMs()).present(over: anchor)
        }
    }

    func hideLinkPreview(anchor: NSView) {
        guard previewAnchor === anchor else { return }
        previewAnchor = nil
        if let previewPopup, let window = anchor.window { PopupHost.host(for: window).close(previewPopup, returnFocus: false) }
        previewPopup = nil
    }
}
