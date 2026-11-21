import CoreGraphics
import Foundation
import ImageIO

// Prepended by scripts/ui/build to winid, shot, record and the input tools. Lists one app's windows from the
// window server, front to back. Window titles need Screen Recording, which the agents' shell already has
// through the T3 runtime that started it.
struct AppWindow {
    let id: CGWindowID
    let layer: Int
    let bounds: CGRect  // global points, top-left origin, the space screencapture -R and CGEvent use
    let onscreen: Bool
    let alpha: Double
    let name: String
}

func appWindows(_ pid: pid_t) -> [AppWindow] {
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
              let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: b as CFDictionary),
              bounds.width > 1, bounds.height > 1 else { return nil }
        return AppWindow(id: CGWindowID(id), layer: w[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                         onscreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false,
                         alpha: w[kCGWindowAlpha as String] as? Double ?? 1, name: w[kCGWindowName as String] as? String ?? "")
    }
}

/// The app's document window: the largest normal-level window, preferring one that is on screen.
func mainWindow(_ pid: pid_t) -> AppWindow? {
    let normal = appWindows(pid).filter { $0.layer == 0 && $0.bounds.width >= 200 && $0.bounds.height >= 150 }
    let pool = normal.contains(where: \.onscreen) ? normal.filter(\.onscreen) : normal
    return pool.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
}

/// The app's other visible windows that belong with the main one: popovers, menus, sheets, tooltips.
func childWindows(_ pid: pid_t, of main: AppWindow) -> [AppWindow] {
    appWindows(pid).filter { $0.id != main.id && $0.onscreen && $0.alpha > 0 && $0.bounds.intersects(main.bounds.insetBy(dx: -64, dy: -64)) }
}

func pidArgument(_ s: String?) -> pid_t? {
    if let s, let p = pid_t(s) { return p }
    return ProcessInfo.processInfo.environment["CW_UI_PID"].flatMap { pid_t($0) }
}

func writePNG(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}
