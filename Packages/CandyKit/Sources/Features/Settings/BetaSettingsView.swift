import AppKit
import DesignSystem
import T3Protocol

/// Settings > Beta (BetaSettingsPanel.tsx at 3669): features still settling in, each off until turned on here.
/// Working section moved here from General; Guest links is new. Signed out of T3 Connect, Guest links offers
/// Sign in in place of its switch (`GuestLinksRowWithSignIn`), but only once the account has loaded.
public final class BetaSettingsView: SettingsPageBase {
    static let guestDetail = "Share a thread with a guest who watches it live in their browser and sends messages you approve. Needs T3 Connect: sign in and link this machine in Connections. While it is off, every guest link stops working."
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
            let signedOut = self.context.connectSignedOut
            guest.detail = signedOut ? Self.guestSignedOutDetail : Self.guestDetail
            guest.detailLink = signedOut ? nil : connections
            let control = signedOut ? signIn : toggle
            if guest.control !== control { guest.control = control }
        }
        items = [section("beta", "Beta", [shelf, guest])]
        binder.refresh()
    }
}
