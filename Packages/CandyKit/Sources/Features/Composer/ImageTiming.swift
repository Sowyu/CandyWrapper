import Foundation

/// Development: with CANDY_IMAGE_TIMING set, prints `image-timing <ms since launch> <event> <detail>`
/// to stderr for thread opens, image requests, fetches, decodes and first pixels (docs/perf/README.md, Images).
public enum ImageTiming {
    public static let enabled = ProcessInfo.processInfo.environment["CANDY_IMAGE_TIMING"] != nil
    private static let start = ContinuousClock.now

    public static func mark(_ event: String, _ detail: @autoclosure () -> String = "") {
        guard enabled else { return }
        let d = ContinuousClock.now - start
        let ms = Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
        FileHandle.standardError.write(Data(String(format: "image-timing %9.1f %@ %@\n", ms, event, detail()).utf8))
    }

    /// Development: CANDY_SLOW_LINK=`<rtt ms>:<Mbit/s>` delays attachment fetches as a remote link would.
    public static let slowLink: (rtt: Double, mbps: Double)? = {
        guard let raw = ProcessInfo.processInfo.environment["CANDY_SLOW_LINK"] else { return nil }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 && parts[1] > 0 ? (parts[0], parts[1]) : nil
    }()

    private static let linkFree = NSLock()
    nonisolated(unsafe) private static var linkBusyUntil = ContinuousClock.now

    /// One round trip, plus `bytes` queued behind the other transfers on one shared link.
    public static func simulateLink(bytes: Int = 0) async {
        guard let link = slowLink else { return }
        let transfer = Duration.seconds(Double(bytes) * 8 / (link.mbps * 1_000_000))
        let done = linkFree.withLock {
            linkBusyUntil = max(linkBusyUntil, .now) + transfer
            return linkBusyUntil
        }
        try? await Task.sleep(until: done + .milliseconds(link.rtt), clock: .continuous)
    }
}
