import AppKit
import AVKit
import DesignSystem

/// MediaVideoPlayer.tsx:31-125. The row hosts native playback controls;
/// re-signing the same attachment does not replace the active player item.
// Audio players belong to the thread while playing, so recycling the row keeps playback.
final class ThreadMediaAttachmentView: DSView {
    let id: String
    let name: String
    let audio: Bool
    private let loader: (@Sendable (String) async -> URL?)?
    private var load: Task<Void, Never>?
    private var player: AVPlayerView?
    private var url: URL?
    private var temporary: URL?
    private var itemStatus: NSKeyValueObservation?
    private let open = ButtonView("Play", icon: .play, variant: .outline, size: .sm)
    private let save = ButtonView("Save", variant: .ghost, size: .xs)
    private var active = false
    private var geometryVisible = false
    private weak var playback: InlineAudioPlayback?
    private let viewer = UUID()
    private var onOpen: (() -> Void)?
    private var windowObserver: NSObjectProtocol?
    init(id: String, name: String, audio: Bool, loader: (@Sendable (String) async -> URL?)?, playback: InlineAudioPlayback? = nil, onOpen: (() -> Void)? = nil) {
        self.id = id; self.name = name; self.audio = audio; self.loader = loader; self.playback = playback; self.onOpen = onOpen
        super.init(frame: .zero)
        addSubview(open); addSubview(save)
        open.title = name; open.toolTip = "Play \(name)"
        open.action = { [weak self] in self?.begin() }
        save.action = { [weak self] in
            guard let self else { return }
            if let onOpen { onOpen() } else { saveMedia() }
        }
        save.title = onOpen != nil ? "Open in file viewer" : (audio ? "Save audio" : "Save video")
    }
    func setVisible(_ visible: Bool) {
        geometryVisible = visible
        updateVisibility()
    }
    private func updateVisibility() {
        let visible = geometryVisible && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        guard visible != active else { return }; active = visible
        if !visible { releasePlayer() }
        else if let kept = playback?.attach(id, viewer: viewer) { show(kept) }
    }
    private func begin() {
        guard active, player == nil, load == nil, let loader else { return }
        open.isEnabled = false
        let playbackGeneration = playback?.generation
        load = Task { [weak self] in
            guard let self else { return }
            let source = await loader(id)
            guard !Task.isCancelled, active, playback?.generation == playbackGeneration else { return }
            guard let source else { load = nil; open.isEnabled = true; open.title = "Retry"; return }
            guard let playable = await InlineAudioSource.playable(source) else { load = nil; open.isEnabled = true; open.title = "Retry"; return }
            guard !Task.isCancelled, active, playback?.generation == playbackGeneration else {
                if let temporary = playable.temporary { try? FileManager.default.removeItem(at: temporary) }
                return
            }
            load = nil; open.isEnabled = true
            url = playable.url
            if playback == nil { temporary = playable.temporary }
            let native = playback?.start(id, url: playable.url, viewer: viewer, temporary: playable.temporary) ?? AVPlayer(url: playable.url)
            show(native)
            native.play()
        }
    }
    private func show(_ native: AVPlayer) {
        guard player == nil else { return }
        let view = AVPlayerView(); view.controlsStyle = .inline
        view.player = native
        itemStatus = native.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let identity = ObjectIdentifier(item)
            Task { @MainActor [weak self] in
                guard let self, let current = player?.player?.currentItem, ObjectIdentifier(current) == identity else { return }
                releasePlayer()
                open.title = "Retry"
                open.toolTip = "Unable to load audio. Retry playback."
            }
        }
        view.setAccessibilityLabel(name)
        player = view; addSubview(view); needsLayout = true
        open.isHidden = true
    }
    func releasePlayer() {
        load?.cancel(); load = nil
        itemStatus = nil
        if let native = player?.player, let playback {
            playback.detach(id, viewer: viewer, continuing: native.currentItem?.status != .failed && native.timeControlStatus != .paused)
        } else { player?.player?.pause() }
        player?.player = nil
        player?.removeFromSuperview(); player = nil
        open.isHidden = false; open.isEnabled = true; url = nil
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            }
        }
        updateVisibility()
    }
    isolated deinit { releasePlayer(); if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
    private func saveMedia() {
        guard let window, let loader else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url, let self else { return }
            Task {
                guard let source = await loader(id) else { return }
                do {
                    let (temp, response) = try await URLSession.shared.download(from: source)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                    if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temp) }
                    else { try FileManager.default.moveItem(at: temp, to: target) }
                } catch { save.title = "Retry save"; save.toolTip = error.localizedDescription }

            }
        }
    }
    override func layout() {
        super.layout()
        open.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(32, bounds.height - 28))
        player?.frame = open.frame
        save.frame = NSRect(x: 0, y: bounds.height - 24, width: min(bounds.width, save.intrinsicContentSize.width), height: 24)
    }
}
