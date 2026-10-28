import AppKit
import DesignSystem
import T3Protocol

/// Settings > Beta (BetaSettingsPanel.tsx at 3669, the Beta section of LabsSettingsPanel.tsx at 3814): features still
/// settling in, each off until turned on here.
/// Working section moved here from General; Guest links is new. Signed out of T3 Connect, Guest links offers
/// Sign in in place of its switch (`GuestLinksRowWithSignIn`), but only once the account has loaded.
public final class BetaSettingsView: SettingsPageBase {
    static let guestDetail = "Share a thread with a guest who watches it live in their browser and sends messages you approve. Needs T3 Connect: sign in and link this machine in Connections. While it is off, every guest link stops working."
    static let linkedDetail = "Let agents here work on your other machines, and theirs here. Turn it on for each machine, then link them in Connections. While it is off, nothing new starts over a link; tasks already running finish."
    static let guestSignedOutDetail = "Share a thread with a guest who watches it live in their browser and sends messages you approve. Sign in to T3 Connect to use guest links."

    public override init(context: SettingsPageContext) {
        super.init(context: context)
        let shelf = clientSwitch("working-shelf",
                                 "Fold working and monitoring threads into a Working section. They return to the top of the inbox when they need you.",
                                 key: "sidebarWorkingShelfEnabled", reset: "working section", label: "Working section", title: "Working section")
        let guest = serverSwitch("guest-links", Self.guestDetail, key: "guestSharingEnabled", reset: nil, label: "Guest links")
        guest.title = "Guest links"
        let connections: (title: String, action: @MainActor () -> Void) = ("Connections", { [weak self] in self?.context.openSection?(.connections) })
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
            guest.detailLink = signedOut ? nil : connections
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
        items = [section("beta", "Beta", [shelf, guest, linked])]
        binder.refresh()
    }
}
