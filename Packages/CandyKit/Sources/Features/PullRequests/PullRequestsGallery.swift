import AppKit
import DesignSystem
import T3Protocol

/// An open pull request in the gallery, for driving the panel's controls on screen without a host:
/// the sandbox has no GitHub token, so its server never answers a pull request detail.
@MainActor
public enum PullRequestsGallery {
    public static var sections: [ComponentGallery.Section] {
        [ComponentGallery.Section(title: "Pull request panel", height: 40) {
            // Its own window: popups need a window whose content view is not a scroll view.
            let open = ButtonView("Open a sample pull request", variant: .outline, size: .sm)
            open.action = { openWindow() }
            open.frame = NSRect(x: 0, y: 0, width: open.intrinsicContentSize.width, height: 32)
            let box = NSView()
            box.addSubview(open)
            return box
        }]
    }

    private static var window: NSWindow?

    public static func openWindow() {
        let view = PullRequestDetailView()
        view.context = .page
        if let d = sample {
            view.activityPending = false
            view.show(d)
            view.changeBreakdown = .loaded(PullRequestChangeBreakdown(code: .init(additions: 301, deletions: 30), tests: .init(additions: 88, deletions: 7),
                                                                      mocks: .init(additions: 0, deletions: 0), generated: .init(additions: 23, deletions: 0)))
        }
        // Stands in for the controller: the action runs for a second and a half.
        view.onAction = { [weak view] _, _ in
            view?.actionPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { view?.actionPending = false }
        }
        let w = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered, defer: false)
        w.title = "Sample pull request"
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// fixtures/pull-requests/detail.json and activity.json, opened, with a bot comment, a resolved thread with
    /// a reply and an open thread whose host holds back two more replies.
    static var sample: PullRequestDetail? {
        let actor = #"{"login":"octocat","name":"The Octocat","avatarUrl":null}"#
        let detail = #"""
        {"provider":"github","projectId":"project-1","projectTitle":"t3code","workspaceRoot":"/workspace/t3code",
         "repository":"pingdotgg/t3code","number":2861,"title":"Add the pull requests page",
         "body":"Lists every pull request across the workspace's projects.","url":"https://github.com/pingdotgg/t3code/pull/2861",
         "author":\#(actor),"state":"open","isDraft":false,"mergeability":"mergeable","additions":412,"deletions":37,"changedFiles":9,
         "headBranch":"feat/pull-requests-page","headRepositoryNameWithOwner":"pingdotgg/t3code","headSha":"3b6af0b5c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6",
         "baseBranch":"main","createdAt":"2026-09-01T10:00:00Z","updatedAt":"2026-09-03T08:00:00Z","mergedAt":null,"closedAt":null,
         "reviewers":[],"labels":[{"name":"enhancement","color":"a2eeef"}],"checks":[{"name":"Unit tests","status":"success","description":null,"url":null,"required":true},
           {"name":"Lint","status":"failure","description":"2 errors","url":"https://github.com/pingdotgg/t3code/actions/runs/1","required":true},
           {"name":"Browser tests (macOS, Chromium)","status":"pending","description":null,"url":"https://github.com/pingdotgg/t3code/actions/runs/2","required":false}],
         "mergeCapabilities":{"merge":true,"squash":true,"rebase":false},"viewer":"octocat","baseComparison":"up-to-date","autoMergeEnabled":false,
         "capabilities":{"diff":true,"comment":true,"actions":["merge","ready","draft","close","reopen","update-branch","enable-auto-merge","disable-auto-merge","revert"],
           "mergeMethods":["merge","squash","rebase"],"updateMethods":["merge","rebase"],"search":true,"reactions":true,"viewedFiles":"host",
           "review":{"inlineComment":true,"reply":true,"resolve":true,"verdicts":["comment","approve","request-changes"]},
           "reviewers":{"request":true,"listCandidates":true},"edit":{"changeRequest":true,"comment":true},"stacks":false,"stackActions":false,"labels":true},
         "viewerPermissions":{"actions":["merge","ready","draft","close","reopen","update-branch","enable-auto-merge","disable-auto-merge","revert"],
           "comment":true,"resolve":true,"verdicts":["comment","approve","request-changes"],"requestReviewers":true,"updateMethods":["merge","rebase"],"labels":true}}
        """#
        let activity = #"""
        {"author":\#(actor),"reviewers":[],"commentCount":7,"commentsTruncated":false,"reviewThreadsTruncated":false,"commits":[],"reactions":[],
         "comments":[
          {"id":"IC_1","kind":"issue-comment","author":{"login":"hubot","name":null,"avatarUrl":null,"isBot":true},"body":"Preview deployed.","createdAt":"2026-09-02T10:00:00Z","url":null,"path":null,"reviewState":null},
          {"id":"RC_1","kind":"review-comment","author":{"login":"reviewer","name":null,"avatarUrl":null},"body":"Nit: name this.","createdAt":"2026-09-02T10:30:00Z","url":null,"path":"apps/web/src/routes/_chat.pull-requests.tsx","reviewState":null},
          {"id":"IC_2","kind":"issue-comment","author":\#(actor),"body":"Ready for another look.","createdAt":"2026-09-02T11:00:00Z","url":null,"path":null,"reviewState":null},
          {"id":"RC_2","kind":"review-comment","author":{"login":"reviewer","name":null,"avatarUrl":null},"body":"This refetches on every focus.","createdAt":"2026-09-02T12:00:00Z","url":"https://github.com/pingdotgg/t3code/pull/2861#discussion_r2","path":"apps/web/src/state/pullRequests.ts","reviewState":null},
          {"id":"RC_3","kind":"review-comment","author":\#(actor),"body":"It keys on the window now.","createdAt":"2026-09-02T12:10:00Z","url":null,"path":"apps/web/src/state/pullRequests.ts","reviewState":null}],
         "reviewThreads":[{"id":"RT_1","path":"apps/web/src/routes/_chat.pull-requests.tsx","line":12,"side":"right","isResolved":true,"isOutdated":false,
           "comments":[{"id":"RC_1","author":{"login":"reviewer","name":null,"avatarUrl":null},"body":"Nit: name this.","createdAt":"2026-09-02T10:30:00Z","url":null},
                       {"id":"RC_1b","author":\#(actor),"body":"Renamed.","createdAt":"2026-09-02T10:40:00Z","url":null}]},
          {"id":"RT_2","path":"apps/web/src/state/pullRequests.ts","line":48,"side":"right","isResolved":false,"isOutdated":false,"commentCount":5,
           "comments":[{"id":"RC_2","author":{"login":"reviewer","name":null,"avatarUrl":null},"body":"This refetches on every focus.","createdAt":"2026-09-02T12:00:00Z","url":"https://github.com/pingdotgg/t3code/pull/2861#discussion_r2"},
                       {"id":"RC_3","author":\#(actor),"body":"It keys on the window now.","createdAt":"2026-09-02T12:10:00Z","url":null}]}]}
        """#
        guard var d = try? JSONDecoder().decode(PullRequestDetail.self, from: Data(detail.utf8)),
              let a = try? JSONDecoder().decode(PullRequestActivity.self, from: Data(activity.utf8)) else { return nil }
        d.apply(a)
        return d
    }
}
