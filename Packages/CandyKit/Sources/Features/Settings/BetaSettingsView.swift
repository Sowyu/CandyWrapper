import AppKit
import DesignSystem
import T3Protocol

/// Settings > Beta (BetaSettingsPanel.tsx at 3669, LabsSettingsPanel.tsx at 4928): features still settling in, each off
/// until turned on here.
/// Working section moved here from General; Guest links is new. Signed out of T3 Connect, Guest links offers
/// Sign in in place of its switch (`GuestLinksRowWithSignIn`), but only once the account has loaded.
public final class BetaSettingsView: SettingsPageBase {
    static let guestDetail = "Share a thread with a guest who watches it live in a browser and sends messages you approve. Needs T3 Connect: sign in and link this machine in Sharing & access. Turning it off stops every guest link."
    static let linkedDetail = "Let agents here work on your other machines, and theirs here. Turn it on for each machine, then link them in Connections. While off, nothing new starts over a link; running tasks finish."
    static let guestSignedOutDetail = "Share a thread with a guest who watches it live in a browser and sends messages you approve. Sign in to T3 Connect to use guest links."

    public override init(context: SettingsPageContext) {
        super.init(context: context)
        // LabsSettingsPanel.tsx:31-51 (4928): the legacy sidebar opt-in is gone (#33131).
        let folders = clientSwitch("boring-sidebar",
            "Group sidebar threads into project folders. Pinned threads stay on top, and Snoozed and Settled stay below the folders.",
            key: "boringSidebarEnabled", label: "Boring sidebar (group by project)", title: "Boring sidebar (group by project)")
        // `BoringSidebarMultilineRow` (LabsSettingsPanel.tsx:54-80 at 4928, #26463), shown while the boring sidebar is on.
        let multiline = clientSwitch("boring-sidebar-multiline",
            "In the boring sidebar, show folder threads on two lines: the title, then the branch, pull request, and agent.",
            key: "boringSidebarMultilineRows", label: "Two-line folder rows", title: "Two-line folder rows")
        binder.add { [weak self, weak multiline] in
            guard let self, let multiline else { return }
            multiline.isHidden = !self.context.client.bool("boringSidebarEnabled")
        }
        let guest = serverSwitch("guest-links", Self.guestDetail, key: "guestSharingEnabled", reset: nil, label: "Guest links")
        guest.title = "Guest links"
        // T3's copy names the Connections group for links and its Sharing & access page for guests (LabsSettingsPanel.tsx at 3814).
        let connections: (title: String, action: @MainActor () -> Void) = ("Connections", { [weak self] in self?.context.openSection?(.connections) })
        let access: (title: String, action: @MainActor () -> Void) = ("Sharing & access", { [weak self] in self?.context.openSection?(.access) })
        // Kept aside, so the row can swap between the switch and Sign in.
        let toggle = guest.control
        let signIn = ButtonView("Sign in", variant: .outline, size: .sm)
        signIn.action = { [weak self] in self?.context.signInToConnect?() }
        binder.add { [weak self, weak guest] in
            guard let self, let guest else { return }
            // Servers before Nightly 3655 have no guest links (settings.ts:1166).
            guest.isHidden = !self.context.scope.allStore("guestSharingEnabled")
            let signedOut = self.context.connectSignedOut
            guest.detail = signedOut ? Self.guestSignedOutDetail : Self.guestDetail
            guest.detailLink = signedOut ? nil : access
            let control = signedOut ? signIn : toggle
            if guest.control !== control { guest.control = control }
        }
        // `LinkedEnvironmentsRow` (LabsSettingsPanel.tsx:101-128 at 3814), per environment like Guest links.
        let linked = serverSwitch("linked-environments-beta", Self.linkedDetail, key: "linkedEnvironmentsEnabled", reset: nil, label: "Linked environments")
        linked.title = "Linked environments"
        linked.detailLink = connections
        binder.add { [weak self, weak linked] in
            guard let self, let linked else { return }
            // Servers before Nightly 3814 can't link (settings.ts:1209, environment.ts:139-142).
            linked.isHidden = !self.context.scope.allStore("linkedEnvironmentsEnabled")
        }
        // `PromptSuggestionsRow` (LabsSettingsPanel.tsx:189-213, #28047): the composer shows the provider's predicted next
        // message. Servers before 4928 don't store the key, so the row waits for one that does.
        let suggestions = serverSwitch("prompt-suggestions-beta",
            "Show a predicted next message in the empty composer after a Claude or Codex turn. Tab uses it. Each is an extra cached request on your plan. Needs Codex 0.165+. Claude threads update on restart.",
            key: "promptSuggestionsEnabled", reset: nil, label: "Suggest next prompt")
        binder.add { [weak self, weak suggestions] in
            guard let self, let suggestions else { return }
            suggestions.isHidden = !self.context.scope.allStore("promptSuggestionsEnabled")
        }
        // #33131 removed the Legacy features section: plan mode and the context window indicator.
        items = [section("beta", "Beta", [folders, multiline, guest, linked, suggestions])]
        binder.refresh()
    }
}
