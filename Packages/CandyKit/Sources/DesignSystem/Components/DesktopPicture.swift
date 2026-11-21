import AppKit

/// The desktop picture as Redesign's Picture background reads it (`DitherArt.desktopPicture`): only from folders
/// macOS never asks the user about, and a debug override for checks.
public enum WallpaperBlur {
    /// How the Desktop places its picture. `.tile` is reachable only through the debug override.
    public enum Placement: String, Sendable, Hashable { case fill, fit, stretch, center, tile }

    // MARK: Guarded folders

    /// Folders macOS asks the user about before an app reads them, relative to the home folder.
    nonisolated static let guardedInHome = ["Desktop", "Documents", "Downloads", ".Trash", "Library/Mobile Documents",
                                            "Library/CloudStorage", "Library/Containers", "Library/Group Containers"]

    /// Whether reading `path` could make macOS ask for permission: the guarded home folders, removable and network
    /// volumes, and photo libraries.
    nonisolated static func isGuarded(_ path: String, home: String) -> Bool {
        let path = (path as NSString).standardizingPath
        func under(_ dir: String) -> Bool { path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") }
        if under("/Volumes") || under("/System/Volumes/Data/Volumes") { return true }
        if path.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) { return true }
        for home in Set([home, "/System/Volumes/Data" + home]) where guardedInHome.contains(where: { under(home + "/" + $0) }) {
            return true
        }
        return false
    }

    /// `path` with its symbolic links resolved one component at a time, or nil if it is guarded or passes through
    /// a guarded folder. It never looks inside a guarded folder, so it can't cause a prompt either.
    nonisolated static func unguardedPath(_ path: String, home: String) -> String? {
        // The home folder can itself be a link, so both spellings count.
        let homes = [home, URL(filePath: home).resolvingSymlinksInPath().path]
        func guarded(_ p: String) -> Bool { homes.contains { isGuarded(p, home: $0) } }
        // Lexical, because `standardizingPath` turns /private/var back into /var, the link it came from.
        func parts(_ p: String) -> [String] {
            p.split(separator: "/").reduce(into: [String]()) { out, c in
                if c == ".." { _ = out.popLast() } else if c != "." { out.append(String(c)) }
            }
        }
        var pending = parts(path)
        var current = "/", hops = 0
        while !pending.isEmpty {
            let candidate = (current as NSString).appendingPathComponent(pending.removeFirst())
            if guarded(candidate) { return nil }
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                if hops > 32 { return nil }
                let absolute = target.hasPrefix("/") ? target : (current as NSString).appendingPathComponent(target)
                pending = parts(absolute) + pending
                current = "/"
            } else {
                current = candidate
            }
        }
        return guarded(current) ? nil : current
    }

    #if DEBUG
    /// Debug-only: a test picture and placement instead of the real desktop, so checks never touch the user's
    /// settings. `CANDY_WALLPAPER=/path/to/image` and optionally `CANDY_WALLPAPER_PLACEMENT=fill|fit|stretch|center|tile`.
    nonisolated static let override: (url: URL, placement: Placement?)? = {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CANDY_WALLPAPER"], !path.isEmpty else { return nil }
        return (URL(filePath: path), env["CANDY_WALLPAPER_PLACEMENT"].flatMap(Placement.init(rawValue:)))
    }()
    #endif
}
