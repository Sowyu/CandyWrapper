import CoreGraphics
import Foundation
import Testing
import T3Protocol
@testable import Features

/// The released 1.15.1 signed a Markdown image path inside a turn of `AssetURLLimit` and the app's `assetURL` signed
/// it again as a `media-file` resource, which waits for a second turn. Six images at once held all six turns while
/// each waited for its second, so no image ever loaded.
@MainActor @Suite(.serialized) struct ImageSigningDeadlockTests {
    @Test func eightPathImagesAtOnceAllSign() async {
        let savedAsset = MarkdownImages.assetURL, savedResource = MarkdownImages.resourceURL
        defer { MarkdownImages.assetURL = savedAsset; MarkdownImages.resourceURL = savedResource }
        // The app's wiring (App/Sources/ThreadSession.swift): a path signs as a `media-file` resource.
        MarkdownImages.assetURL = { path in
            await MarkdownImages.signedURL(resource: .object(["_tag": .string("media-file"), "path": .string(path)]))
        }
        MarkdownImages.resourceURL = { resource in
            guard let path = resource["path"]?.stringValue, path.hasPrefix("/image-stuck/") else { return nil }
            try? await Task.sleep(for: .milliseconds(20))
            return (URL(string: "http://127.0.0.1:1\(path)")!, nil)
        }
        let paths = (0..<8).map { "/image-stuck/\($0).png" }
        let signing = Task {
            await withTaskGroup(of: URL?.self) { group in
                for path in paths { group.addTask { await MarkdownImages.signedURL(path)?.url } }
                var urls: [URL?] = []
                for await url in group { urls.append(url) }
                return urls
            }
        }
        // A deadlock ends here: cancelling makes every waiter give up, so the test fails instead of hanging. The fix
        // signs all eight in milliseconds; the margin is for a full parallel run that starves the cooperative pool.
        let deadline = Task { try? await Task.sleep(for: .seconds(30)); signing.cancel() }
        let urls = await signing.value
        deadline.cancel()
        #expect(urls.compactMap { $0 }.count == 8)
    }

    /// Thousands of random sequences through the app's path: views ask for path images through
    /// `MarkdownImageDownload`, `MarkdownImages.signedURL`, the shared limit and a fake server that answers, fails,
    /// never answers until the app's timeout, or drops every call when its connection goes down. Views cancel while
    /// they wait and while they sign, and ask again for keys already in flight. Every request must end, at most six
    /// calls may reach the server at once, and once the server answers again every image must load.
    @Test func randomSigningStress() async {
        let savedAsset = MarkdownImages.assetURL, savedResource = MarkdownImages.resourceURL
        defer { MarkdownImages.assetURL = savedAsset; MarkdownImages.resourceURL = savedResource }
        let server = FakeSigner()
        MarkdownImages.assetURL = { path in
            await MarkdownImages.signedURL(resource: .object(["_tag": .string("media-file"), "path": .string(path)]))
        }
        MarkdownImages.resourceURL = { resource in await server.sign(resource["path"]?.stringValue ?? "") }
        for seed in UInt64(1)...2000 {
            if let failure = await Self.sequence(seed: seed, server: server) {
                Issue.record("seed \(seed): \(failure)")
                break
            }
        }
        #expect(await server.peak <= 6)
        #expect(await server.peak == 6)
    }

    /// Nil when the sequence passed, else what went wrong.
    private static func sequence(seed: UInt64, server: FakeSigner) async -> String? {
        var random = SplitMix(seed: seed)
        await server.reset(seed: seed &* 31)
        let keys = Int.random(in: 1...14, using: &random)
        let downloads = (0..<keys).map { key in
            MarkdownImageDownload {
                guard let asset = await MarkdownImages.signedURL("/stress/\(seed)/\(key).png") else { return nil }
                return ImageDownloadFile(missingFolder.appending(path: asset.url.lastPathComponent))
            }
        }
        // Which key each view asks for, and when it is cancelled (microseconds), if at all.
        let views = (0..<Int.random(in: keys...(keys * 3), using: &random)).map { _ in
            (key: Int.random(in: 0..<keys, using: &random), cancel: Bool.random(using: &random) ? Int.random(in: 0...400, using: &random) : nil)
        }
        let drop = Int.random(in: 0...3, using: &random) == 0 ? Int.random(in: 0...300, using: &random) : nil
        let asked = Task {
            await withTaskGroup(of: Void.self) { group in
                for view in views {
                    let download = downloads[view.key]
                    let request = Task { await download.value() }
                    group.addTask { _ = await request.value }
                    if let after = view.cancel {
                        group.addTask { try? await Task.sleep(for: .microseconds(after)); request.cancel() }
                    }
                }
                if let drop { group.addTask { try? await Task.sleep(for: .microseconds(drop)); await server.disconnect() } }
            }
        }
        guard await finishes(asked, within: .seconds(10)) else { return "a request waited forever" }
        await server.answerAll()
        let again = Task {
            await withTaskGroup(of: Bool.self) { group in
                for download in downloads { group.addTask { await download.value() != nil } }
                var loaded = true
                for await ok in group where !ok { loaded = false }
                return loaded
            }
        }
        guard await finishes(again, within: .seconds(10)) else { return "an image stayed stuck after the server recovered" }
        guard await again.value else { return "an image failed after the server recovered" }
        let peak = await server.peak
        return peak > 6 ? "\(peak) calls reached the server at once" : nil
    }

    /// Waits for `task`; false, and cancels it, when it takes longer than `limit`.
    private static func finishes<T>(_ task: Task<T, Never>, within limit: Duration) async -> Bool {
        let late = Task {
            try? await Task.sleep(for: limit)
            if Task.isCancelled { return false }
            task.cancel()
            return true
        }
        _ = await task.value
        late.cancel()
        return await late.value == false
    }
}

private let missingFolder = FileManager.default.temporaryDirectory.appending(path: "image-stuck-missing-\(UUID().uuidString)")

/// `assets.createUrl` on a fake server. Half the calls answer after up to 0.3 ms, a fifth fail, and the rest never
/// answer: those give up after 2 ms the way the app's call does after `MarkdownImages.signingTimeout`, or fail when
/// the connection drops, like `RPCConnection` failing its pending calls.
private actor FakeSigner {
    private var random = SplitMix(seed: 0)
    private var answering = false
    private var hung: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var now = 0
    private(set) var peak = 0

    func reset(seed: UInt64) { random = SplitMix(seed: seed); answering = false }
    func answerAll() { answering = true }
    func disconnect() {
        let calls = hung
        hung = [:]
        for call in calls.values { call.resume() }
    }

    func sign(_ path: String) async -> (url: URL, size: CGSize?)? {
        guard path.hasPrefix("/stress/") else { return nil }
        now += 1
        peak = max(peak, now)
        defer { now -= 1 }
        let url = URL(string: "http://127.0.0.1:1" + path)!
        if answering { return (url, nil) }
        switch Int.random(in: 0..<10, using: &random) {
        case 0..<5:
            try? await Task.sleep(for: .microseconds(Int.random(in: 0...300, using: &random)))
            return Task.isCancelled ? nil : (url, nil)
        case 5..<7:
            return nil
        default:
            await hang(timeout: .milliseconds(2))
            return nil
        }
    }

    private func hang(timeout: Duration) async {
        let id = UUID()
        let timer = Task { try? await Task.sleep(for: timeout); self.drop(id) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { call in
                if Task.isCancelled { call.resume() } else { hung[id] = call }
            }
        } onCancel: {
            Task { await self.drop(id) }
        }
        timer.cancel()
    }

    private func drop(_ id: UUID) { hung.removeValue(forKey: id)?.resume() }
}
