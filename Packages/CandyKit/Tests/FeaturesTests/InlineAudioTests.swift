import AppKit
import AVFoundation
import Testing
import T3Protocol
@testable import Features

@MainActor struct InlineAudioTests {
    @Test func playingAudioSurvivesRowRecyclingAndStopsWithItsThread() {
        let playback = InlineAudioPlayback()
        let first = UUID(), second = UUID()
        let url = URL(fileURLWithPath: "/sandbox/audio.wav")
        let player = playback.start("attachment-a", url: url, viewer: first)
        playback.detach("attachment-a", viewer: first, continuing: true)
        #expect(playback.attach("attachment-a", viewer: second) === player)
        playback.detach("attachment-a", viewer: second, continuing: false)
        #expect(playback.attach("attachment-a", viewer: first) == nil)
        let next = playback.start("attachment-a", url: url, viewer: first)
        #expect(next !== player)
        let generation = playback.generation
        playback.clear()
        #expect(playback.generation != generation)
        #expect(next.currentItem == nil)
        #expect(playback.attach("attachment-a", viewer: first) == nil)
    }

    @Test func dataAudioCopiesFollowThePlayerLifetime() async throws {
        let data = try #require(URL(string: "data:audio/wav;base64,UklGRg=="))
        let playable = try #require(await InlineAudioSource.playable(data))
        #expect(playable.url.isFileURL && FileManager.default.fileExists(atPath: playable.url.path))
        let playback = InlineAudioPlayback(), viewer = UUID()
        _ = playback.start("data", url: playable.url, viewer: viewer, temporary: playable.temporary)
        playback.clear()
        #expect(!FileManager.default.fileExists(atPath: playable.url.path))
    }

    @Test func audioEmbedsUseCompactPlayersAndArbitraryFilesBecomeChips() {
        #expect(InlineAudioSource.isAudio(name: "https://example.com/audio.WAV?token=test"))
        #expect(InlineAudioSource.isAudio(name: "clip.webm-audio"))
        #expect(InlineAudioSource.isAudio(name: "file", mimeType: "audio/mp4"))
        #expect(InlineAudioSource.isAudio(name: "data:audio/wav;base64,AA=="))
        #expect(!InlineAudioSource.isAudio(name: "image.png"))
        let audio = MarkdownLayout(document: .init(parsing: "![Audio](/tmp/clip.mp3)"), width: 400, cwd: "/sandbox")
        #expect(audio.height < 120 && audio.images.count == 1)
        let file = MarkdownLayout(document: .init(parsing: "![Archive](/tmp/result.zip)"), width: 400, cwd: "/sandbox")
        #expect(file.images.isEmpty && file.fileChips.count == 1)
    }

    @Test func binaryDownloadsNeverSendNewDispositionToOlderServers() {
        for version in [nil, "bad", "0.1.3-nightly.20261024.3473", "0.1.3-nightly.20261025.3669", "0.1.3-nightly.20261026.3717", "0.1.4-nightly.20261027.3754"] {
            #expect(FileAssetRules.binaryResource(version: version, threadId: "t", path: "/sandbox/a.zip") == nil)
        }
        let resource = FileAssetRules.binaryResource(version: "0.1.4-nightly.20261028.3814", threadId: "t", path: "/sandbox/a.zip")
        #expect(resource?["_tag"] == .string("media-file") && resource?["disposition"] == .string("attachment"))
        #expect(resource?["threadId"] == .string("t") && resource?["path"] == .string("/sandbox/a.zip"))
    }
}
