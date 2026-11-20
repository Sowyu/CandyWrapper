import Testing
import T3Protocol
import T3Store
@testable import Features

/// On Settings, Pull Requests, Issues and Usage the window title is the app's name, as T3 reads the open thread
/// from the route (appInit.tsx:130-137, 149-186 and branding.logic.ts:70-74 at 4928). 1.15.0 kept the last thread's.
@MainActor @Suite struct RouteWindowTitleTests {
    static func title(_ route: RouteHistory.Route) -> String {
        let open: ThreadId? = route.titlesOpenThread ? ThreadId("t") : nil
        return WindowTitle.resolve(appName: "CandyWrapper", projectTitle: open == nil ? nil : "demo-repo",
                                   threadTitle: open == nil ? nil : "Blue", screenReader: nil)
    }

    @Test func pagesWithoutAThreadTitleTheApp() {
        #expect(Self.title(.thread(ThreadId("t"))) == "demo-repo / Blue")
        #expect(Self.title(.draft("d")) == "demo-repo / Blue")
        for route: RouteHistory.Route in [.settings(.general), .pullRequests, .issues, .usage] {
            #expect(Self.title(route) == "CandyWrapper", "\(route)")
        }
    }
}
