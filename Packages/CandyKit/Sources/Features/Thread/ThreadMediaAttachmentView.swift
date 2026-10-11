import AppKit
import AVKit
import DesignSystem

/// MediaVideoPlayer.tsx:31-125. A visible attachment owns its native player;
/// re-signing the same attachment does not replace the active player item.
// ponytail: native playback controls and user attachments only, add source-matched controls and Markdown media when their renderer is ported.
final class ThreadMediaAttachmentView: DSView {
    let id: String
    let name: String
    let audio: Bool
    private let loader: (@Sendable (String) async -> URL?)?
    private var load: Task<Void, Never>?
    private var player: AVPlayerView?
    private var url: URL?
    private let open = ButtonView("Play", icon: .play, variant: .outline, size: .sm)
    private let save = ButtonView("Save", variant: .ghost, size: .xs)
    private var active = false
    private var geometryVisible = false
    private var windowObserver: NSObjectProtocol?
    init(id: String, name: String, audio: Bool, loader: (@Sendable (String) async -> URL?)?) {
        self.id = id; self.name = name; self.audio = audio; self.loader = loader
        super.init(frame: .zero)
        addSubview(open); addSubview(save)
        open.title = name; open.toolTip = "Play \(name)"
        open.action = { [weak self] in self?.begin() }
        save.action = { [weak self] in self?.saveMedia() }
        save.title = audio ? "Save audio" : "Save video"
    }
    func setVisible(_ visible: Bool) {
        geometryVisible = visible
        updateVisibility()
    }
    private func updateVisibility() {
        let visible = geometryVisible && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        guard visible != active else { return }; active = visible
        if !visible { releasePlayer() }
    }
    private func begin() {
        guard active, player == nil, load == nil, let loader else { return }
        open.isEnabled = false
        load = Task { [weak self] in
            guard let self else { return }
            let source = await loader(id)
            guard !Task.isCancelled, active else { return }
            load = nil; open.isEnabled = true
            guard let source else { open.title = "Retry"; return }
            url = source
            let view = AVPlayerView(); view.controlsStyle = .inline
            view.player = AVPlayer(url: source)
            player = view; addSubview(view); needsLayout = true
            open.isHidden = true
            view.player?.play()
        }
    }
    func releasePlayer() {
        load?.cancel(); load = nil
        player?.player?.pause(); player?.player = nil
        player?.removeFromSuperview(); player = nil
        open.isHidden = false; open.isEnabled = true; url = nil
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
    isolated deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
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
        save.frame = NSRect(x: 0, y: bounds.height - 24, width: 100, height: 24)
    }
}
