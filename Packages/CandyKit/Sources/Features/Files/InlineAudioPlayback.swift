import AppKit
import AVFoundation

/// T3 3814 files/AudioPreview.tsx:19-101 keeps active audio outside virtualized rows. The
/// thread owns players while audio plays; detached paused rows keep only their seek position.
@MainActor public final class InlineAudioPlayback {
    @MainActor private final class Entry {
        let id = UUID()
        let player: AVPlayer
        var viewers: Set<UUID> = []
        var ended: NSObjectProtocol?
        var temporary: URL?
        init(_ player: AVPlayer) { self.player = player }
    }
    private var entries: [String: Entry] = [:]
    private var positions: [String: CMTime] = [:]
    private(set) var generation = 0
    public init() {}

    func attach(_ key: String, viewer: UUID) -> AVPlayer? {
        guard let entry = entries[key] else { return nil }
        entry.viewers.insert(viewer)
        return entry.player
    }

    func start(_ key: String, url: URL, viewer: UUID, temporary: URL? = nil) -> AVPlayer {
        if let player = attach(key, viewer: viewer) {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            return player
        }
        let player = AVPlayer(url: url)
        if let time = positions[key], time.isNumeric { player.seek(to: time) }
        let entry = Entry(player)
        entry.temporary = temporary
        entry.viewers.insert(viewer)
        let identity = entry.id
        entry.ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let entry = self.entries[key], entry.id == identity else { return }
                self.positions[key] = .zero
                if entry.viewers.isEmpty { self.remove(key) }
            }
        }
        entries[key] = entry
        return player
    }

    func detach(_ key: String, viewer: UUID, continuing: Bool) {
        guard let entry = entries[key] else { return }
        entry.viewers.remove(viewer)
        guard entry.viewers.isEmpty, !continuing else { return }
        let time = entry.player.currentTime()
        if time.isNumeric {
            let duration = entry.player.currentItem?.duration ?? .indefinite
            positions[key] = duration.isNumeric && CMTimeCompare(time, duration) >= 0 ? .zero : time
        }
        remove(key)
    }

    private func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let ended = entry.ended { NotificationCenter.default.removeObserver(ended) }
        entry.player.pause()
        entry.player.replaceCurrentItem(with: nil)
        if let temporary = entry.temporary { try? FileManager.default.removeItem(at: temporary) }
    }

    public func clear() {
        generation &+= 1
        for key in Array(entries.keys) { remove(key) }
        positions = [:]
    }

    isolated deinit {
        for entry in entries.values {
            if let ended = entry.ended { NotificationCenter.default.removeObserver(ended) }
            entry.player.pause()
            entry.player.replaceCurrentItem(with: nil)
            if let temporary = entry.temporary { try? FileManager.default.removeItem(at: temporary) }
        }
    }
}

public enum InlineAudioSource {
    public static func isAudio(name: String, mimeType: String = "") -> Bool {
        if mimeType.lowercased().hasPrefix("audio/") || name.lowercased().hasPrefix("data:audio/") { return true }
        let path = URL(string: name)?.path.removingPercentEncoding ?? name.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? name
        return FilePreviewKind.of(path) == .audio
    }

    /// AVFoundation needs a file URL for a data URI. Its temporary copy follows the player,
    /// including continued playback after the row leaves the viewport.
    static func playable(_ source: URL) async -> (url: URL, temporary: URL?)? {
        guard source.scheme?.lowercased() == "data" else { return (source, nil) }
        return await Task.detached(priority: .userInitiated) { () -> (url: URL, temporary: URL?)? in
            let raw = source.absoluteString
            guard raw.utf8.count <= 70 * 1024 * 1024, let comma = raw.firstIndex(of: ",") else { return nil }
            let header = raw[..<comma].lowercased()
            guard header.hasPrefix("data:audio/") else { return nil }
            let payload = String(raw[raw.index(after: comma)...])
            let bytes = header.contains(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
            guard let bytes, bytes.count <= 50 * 1024 * 1024 else { return nil }
            let ext = ["wav", "ogg", "aiff", "flac", "aac", "webm"].first(where: header.contains) ?? (header.contains("mp4") ? "m4a" : "mp3")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("cw-inline-audio-" + UUID().uuidString).appendingPathExtension(ext)
            do { try bytes.write(to: file); return (file, file) } catch { return nil }
        }.value
    }

}
