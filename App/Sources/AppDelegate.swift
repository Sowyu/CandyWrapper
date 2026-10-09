import AppKit
import DesignSystem

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var galleryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        showMainWindow()
        if CommandLine.arguments.contains("--gallery") { showGallery(nil) }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func showMainWindow() {
        // The official desktop app opens at 1100x780 with a minimum of 840x620.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 840, height: 620)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "CandyWrapper"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
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
