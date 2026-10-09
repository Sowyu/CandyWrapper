import AppKit
import DesignSystem
import Features

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var galleryWindow: NSWindow?
    private var session: ShellSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        showMainWindow()
        if CommandLine.arguments.contains("--gallery") { showGallery(nil) }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func showMainWindow() {
        let window = MainWindow()
        let sidebar = SidebarContentView()
        let main = TopbarDragView()
        let layout = SidebarLayoutView(sidebarContent: sidebar, mainContent: main)
        window.contentView = layout
        sidebar.actions.toggleSidebar = { [weak layout] in layout?.toggle() }
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        window.layoutTrafficLights()
        mainWindow = window
        if CommandLine.arguments.contains("--chrome-check") { chromeCheck(window, toggle: sidebar.trigger) }
        startSession(sidebar: sidebar)
        scheduleSelfSnapshot(window)
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

    /// Development entry until the server manager lands:
    /// `--server http://127.0.0.1:47391 --token-file <path to a bearer token>`.
    private func startSession(sidebar: SidebarContentView) {
        let args = CommandLine.arguments
        guard let s = args.firstIndex(of: "--server"), s + 1 < args.count, let url = URL(string: args[s + 1]),
              let t = args.firstIndex(of: "--token-file"), t + 1 < args.count,
              let token = try? String(contentsOfFile: args[t + 1], encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return }
        let session = ShellSession(baseURL: url, token: token, sidebar: sidebar)
        session.start()
        self.session = session
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
        appMenu.addItem(withTitle: "Quit CandyWrapper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Hidden: the gallery is a developer tool, reachable only by shortcut or --gallery.
        let gallery = NSMenuItem(title: "Component Gallery", action: #selector(showGallery(_:)), keyEquivalent: "g")
        gallery.keyEquivalentModifierMask = [.command, .option, .shift]
        gallery.isHidden = true
        gallery.allowsKeyEquivalentWhenHidden = true
        appMenu.addItem(gallery)
        appItem.submenu = appMenu
        return main
    }
}
