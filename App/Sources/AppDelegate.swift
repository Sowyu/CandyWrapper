import AppKit
import DesignSystem
import Features

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var galleryWindow: NSWindow?
    private var session: ShellSession?
    private var server: ServerController?
    private var threads: ThreadController?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
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
        server?.shouldTerminate() ?? .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func showMainWindow() {
        let window = MainWindow()
        let sidebar = SidebarContentView()
        let threads = ThreadController(sidebar: sidebar, window: window)
        self.threads = threads
        let main: NSView = Self.threadPreview() ?? threads.panel
        let layout = SidebarLayoutView(sidebarContent: sidebar, mainContent: main)
        window.contentView = layout
        sidebar.actions.toggleSidebar = { [weak layout] in layout?.toggle() }
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        window.layoutTrafficLights()
        mainWindow = window
        if CommandLine.arguments.contains("--chrome-check") { chromeCheck(window, toggle: sidebar.trigger) }
        startSession(sidebar: sidebar, window: window)
        scheduleSelfSnapshot(window)
    }

    /// Development: `--thread-preview [title prefix]` shows a recorded thread from
    /// fixtures/transcripts/04-threads.jsonl in the main panel (default: the markdown thread).
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

    /// The local server through `ServerController`. Development: `--server <url> --token-file
    /// <path>` connects straight to a running server instead, such as the sandbox on 47391.
    private func startSession(sidebar: SidebarContentView, window: NSWindow) {
        let args = CommandLine.arguments
        // A preview never connects, so it never starts or joins a server.
        if args.contains("--thread-preview") { return }
        guard let s = args.firstIndex(of: "--server"), s + 1 < args.count, let url = URL(string: args[s + 1]),
              let t = args.firstIndex(of: "--token-file"), t + 1 < args.count,
              let token = try? String(contentsOfFile: args[t + 1], encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            let server = ServerController(sidebar: sidebar, window: window)
            server.onShell = { [weak self] in self?.threads?.follow($0, environment: $1) }
            server.start()
            self.server = server
            return
        }
        let session = ShellSession(baseURL: url, token: token, sidebar: sidebar)
        session.start()
        self.session = session
        threads?.follow(session, environment: url.absoluteString)
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
        let appMenu = NSMenu()
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
        return main
    }

    /// Cmd+Opt+Shift+L: the open thread's timeline report to /tmp/cw-timeline-<pid>.txt and stdout.
    @objc func logTimeline(_ sender: Any?) {
        guard let report = threads?.panel.timeline.debugReport() else { return }
        let path = "/tmp/cw-timeline-\(getpid()).txt"
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
        print(report)
        NSLog("timeline report written to %@", path)
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
