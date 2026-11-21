import AppKit
import ScreenCaptureKit

// Prepended by scripts/ui/build to record, after windows.swift. Picks what ScreenCaptureKit captures for one
// app so the picture is right while other windows cover it:
// - The app's main window and the child windows over it (popovers, menus, sheets, tooltips), composited by
//   the window server with every other app left out, when the main window sits fully on one display.
// - Only the main window, at its full size, when it is partly off screen or on another Space. Child windows
//   are then missing, and the tool says so.

struct Target {
    let filter: SCContentFilter
    let config: SCStreamConfiguration
    let origin: CGPoint  // global point of the picture's top-left corner
    let scale: CGFloat   // pixels per point
    let note: String
}

func captureTarget(pid: pid_t, wantChildren: Bool = true) async throws -> Target {
    guard let main = mainWindow(pid) else { throw Failure("no window for pid \(pid)") }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let scMain = content.windows.first(where: { $0.windowID == main.id }) else { throw Failure("window \(main.id) is not capturable") }
    let children = wantChildren ? childWindows(pid, of: main) : []
    let region = children.reduce(main.bounds) { $0.union($1.bounds) }
    let config = SCStreamConfiguration()
    config.showsCursor = false
    config.captureResolution = .best
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.ignoreShadowsSingleWindow = true
    config.ignoreShadowsDisplay = true
    if main.onscreen, let display = content.displays.first(where: { $0.frame.contains(region) }),
       let app = content.applications.first(where: { $0.processID == pid }) {
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        config.sourceRect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int((region.width * scale).rounded())
        config.height = Int((region.height * scale).rounded())
        config.backgroundColor = .clear
        return Target(filter: filter, config: config, origin: region.origin, scale: scale, note: "windows \(1 + children.count)")
    }
    let filter = SCContentFilter(desktopIndependentWindow: scMain)
    let scale = CGFloat(filter.pointPixelScale)
    config.width = Int((main.bounds.width * scale).rounded())
    config.height = Int((main.bounds.height * scale).rounded())
    let why = main.onscreen ? "partly off screen" : "not on the current Space"
    let note = children.isEmpty ? "window only (\(why))" : "window only (\(why)): \(children.count) child windows left out"
    return Target(filter: filter, config: config, origin: main.bounds.origin, scale: scale, note: note)
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Runs the async body on a task and keeps the main run loop going, as ScreenCaptureKit needs.
func runMain(watchdogSeconds: Int = 20, _ body: @escaping @Sendable () async throws -> Void) -> Never {
    MainActor.assumeIsolated { _ = NSApplication.shared }  // CGS needs an app connection before ScreenCaptureKit starts
    // ScreenCaptureKit's daemon, replayd, stopped answering for minutes on 2026-11-20. Fail instead of hanging.
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(watchdogSeconds)) {
        FileHandle.standardError.write(Data("ScreenCaptureKit did not answer in \(watchdogSeconds) s (replayd busy); try again later\n".utf8))
        exit(5)
    }
    Task {
        do { try await body(); exit(0) } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
        }
    }
    RunLoop.main.run()
    exit(0)
}
