import AppKit

/// Native equivalent of pullRequestContextDrag.ts. The source carries the PR snapshot, so a
/// drop creates a context chip without a network round trip.
public enum PullRequestDrag {
    public static let type = NSPasteboard.PasteboardType("com.candywrapper.pull-request")
    public static func read(_ board: NSPasteboard) -> PullRequestReference? {
        guard let data = board.data(forType: type), data.count < 65_536,
              let pr = try? JSONDecoder().decode(PullRequestReference.self, from: data),
              pr.number > 0, let url = URL(string: pr.url), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return pr
    }
}
