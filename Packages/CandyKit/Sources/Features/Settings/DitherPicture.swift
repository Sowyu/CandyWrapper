import AppKit
import UniformTypeIdentifiers

/// The Dither theme's picture. A chosen file is copied into Application Support under a new name, so the backdrop
/// never reads a folder macOS guards and each pick renders afresh. Without one the theme dithers the desktop picture.
@MainActor
public enum DitherPicture {
    static let key = "ditherPicturePath"

    public static var path: String? {
        guard let p = UserDefaults.standard.string(forKey: key), FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: Bundle.main.bundleIdentifier ?? "CandyWrapper").appending(path: "Dither")
    }

    /// Copies `url` in and makes it the picture, removing the one it replaces.
    public static func set(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        let target = folder.appending(path: "\(UUID().uuidString).\(ext)")
        try fm.copyItem(at: url, to: target)
        if let old = UserDefaults.standard.string(forKey: key) { try? fm.removeItem(atPath: old) }
        UserDefaults.standard.set(target.path, forKey: key)
    }

    /// Back to the desktop picture.
    public static func clear() {
        if let old = UserDefaults.standard.string(forKey: key) { try? FileManager.default.removeItem(atPath: old) }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// An open panel for an image; `done` runs after a successful pick.
    public static func choose(in window: NSWindow?, onError: @escaping (String) -> Void, done: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for the Redesign theme."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try set(url); done() } catch { onError(error.localizedDescription) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }
}
