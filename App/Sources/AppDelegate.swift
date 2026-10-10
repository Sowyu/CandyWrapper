import AppKit
import DesignSystem
import Features

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var galleryWindow: NSWindow?
    private var environments: Environments?
    private var server: ServerController?
    private var threads: ThreadController?
    private var settings: SettingsController?
    private var sidebarCommands: SidebarCommands?
    private var t3Connect: T3ConnectController?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        // Development: `--appearance light|dark` sets the app's own appearance, leaving the system's alone.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        quitOnSIGTERM()
        showMainWindow()
        if CommandLine.arguments.contains("--gallery") { showGallery(nil) }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
        guard let server else { environments?.stopAll(); return .terminateNow }
        return server.shouldTerminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func showMainWindow() {
        let window = MainWindow()
        let sidebar = SidebarContentView()
        // Development: `--fake-t3-connect` swaps T3 Connect's Clerk and relay for in-process fakes and keeps
        // saved environments in a temporary catalog (FakeT3Connect).
        let fakeConnect = CommandLine.arguments.contains("--fake-t3-connect")
        let environments = fakeConnect ? Environments(sidebar: sidebar, catalog: FakeT3Connect.catalog()) : Environments(sidebar: sidebar)
        self.environments = environments
        let t3Connect = T3ConnectController(environments: environments, fake: fakeConnect)
        self.t3Connect = t3Connect
        let threads = ThreadController(sidebar: sidebar, window: window, environments: environments)
        self.threads = threads
        let main: NSView = Self.threadPreview() ?? threads.panel
        let layout = SidebarLayoutView(sidebarContent: sidebar, mainContent: main)
        window.contentView = layout
        sidebar.actions.toggleSidebar = { [weak layout] in layout?.toggle() }
        let settings = SettingsController(window: window, layout: layout, threadSidebar: sidebar, threadPanel: main, environments: environments,
                                          t3: t3Connect)
        self.settings = settings
        let commands = SidebarCommands(sidebar: sidebar, window: window, layout: layout, environments: environments, threads: threads)
        self.sidebarCommands = commands
        sidebar.actions.openSettings = { [weak settings, weak commands] in commands?.closeUtilityPage(); settings?.open() }
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        window.layoutTrafficLights()
        mainWindow = window
        if CommandLine.arguments.contains("--chrome-check") { chromeCheck(window, toggle: sidebar.trigger) }
        startSession(environments, window: window)
        if !Self.isPreview { t3Connect.start() }
        scheduleSelfSnapshot(window)
        PerfScroll.schedule(window)
    }

    /// Development: `--thread-preview [title prefix]` shows a recorded thread from
    /// fixtures/transcripts/04-threads.jsonl in the main panel (default: the markdown thread).
    private static var isPreview: Bool { CommandLine.arguments.contains("--thread-preview") }

    private static func threadPreview() -> NSView? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--thread-preview") else { return nil }
        let title = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : ThreadPreview.markdownThread
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
        let servers = Self.developmentServers(args)
        guard servers.isEmpty else {
            for (i, server) in servers.enumerated() { environments.addDevelopment(baseURL: server.url, token: server.token, primary: i == 0) }
            // Saved environments connect at launch whatever the primary is, as in T3.
            environments.restoreSaved()
            return
        }
        let server = ServerController(environments: environments, window: window)
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

    @objc func showGallery(_ sender: Any?) {
        if galleryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Component Gallery"
            window.isReleasedWhenClosed = false
            ComponentGallery.extraSections = [MarkdownGallery.section] + DiffGallery.sections + PickersGallery.sections
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
        // ponytail: no Check for Updates, File, View or Help yet; add them with packaging (M9)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About CandyWrapper", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
        appMenu.addItem(withTitle: "Quit CandyWrapper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        appItem.submenu = appMenu
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = makeEditMenu()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
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

    /// Cmd+Opt+Shift+L: the open thread's timeline report to /tmp/cw-timeline-<pid>.txt and stdout.
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
