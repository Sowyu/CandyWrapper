import Foundation
import T3Protocol

/// The server runtime follows T3's channel selection (updates/updateChannels.ts:3-18 at 3234).
/// Checks run once after launch and on activation, never from an idle poller.
public enum RuntimeUpdatePolicy {
    public enum Channel: String, Sendable { case latest, nightly }
    public static func channel(for version: String) -> Channel {
        version.range(of: #"^[^-+]+-nightly\.\d{8}\.\d+$"#, options: .regularExpression) != nil ? .nightly : .latest
    }
    public static func shouldCheck(now: Date, launchedAt: Date, lastCheck: Date?, owned: Bool, busy: Bool) -> Bool {
        owned && !busy && now.timeIntervalSince(launchedAt) >= 15
            && (lastCheck.map { now.timeIntervalSince($0) >= 240 } ?? true)
    }
    public static func update(current: String, releases: [RuntimeRelease]) -> RuntimeRelease? {
        guard let current = T3Version(current) else { return nil }
        let channel = channel(for: current.raw)
        return releases.filter { release in
            guard !release.draft, let version = T3Version(release.version), version > current,
                  release.assets.contains("SHA256SUMS"),
                  release.assets.contains("t3-\(version.raw)-darwin-arm64.tar.gz") else { return false }
            switch channel {
            case .nightly: return self.channel(for: version.raw) == .nightly
            case .latest: return !release.prerelease && !version.raw.contains("-")
            }
        }.max { T3Version($0.version)! < T3Version($1.version)! }
    }
}

public struct RuntimeRelease: Decodable, Equatable, Sendable {
    public var version: String
    public var draft: Bool
    public var prerelease: Bool
    public var assets: Set<String>
    public init(version: String, draft: Bool = false, prerelease: Bool = false, assets: Set<String>) {
        self.version = version; self.draft = draft; self.prerelease = prerelease; self.assets = assets
    }
    private enum CodingKeys: String, CodingKey { case tag_name, draft, prerelease, assets }
    public init(from decoder: any Decoder) throws {
        struct Asset: Decodable { var name: String }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .tag_name)
        version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        draft = try c.decode(Bool.self, forKey: .draft)
        prerelease = try c.decode(Bool.self, forKey: .prerelease)
        assets = Set(try c.decode([Asset].self, forKey: .assets).map(\.name))
    }
    public static func fetch(channel: RuntimeUpdatePolicy.Channel, session: URLSession = .shared) async throws -> [Self] {
        let endpoint = channel == .nightly ? "releases?per_page=100" : "releases/latest"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/pingdotgg/t3code/" + endpoint)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CandyWrapper", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try RuntimeStore.checkStatus(response, "checking T3 Code releases")
        return channel == .nightly ? try JSONDecoder().decode([Self].self, from: data) : [try JSONDecoder().decode(Self.self, from: data)]
    }
}
