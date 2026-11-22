import Foundation

/// Words for a failed app update check, read from Sparkle's `NSError` chain, and whether one retry may help.
/// Sparkle wraps every feed fetch failure in `SUDownloadError` (2001) "An error occurred in retrieving update
/// information. Please try again later." (SUAppcastDriver.m:283-294 in Sparkle 2.10.0) and keeps the cause
/// underneath: an `NSURLErrorDomain` error, or a `SUDownloadError` whose text ends in the HTTP status
/// (SPUDownloader.m:191-205).
public enum UpdateCheckError {
    static let sparkleDomain = "SUSparkleErrorDomain"
    static let appcastParse = 1000, appcastError = 1002, downloadError = 2001, signatureError = 3001, validationError = 3002

    /// How long the one retry of a transient failure waits.
    public static let retryDelay: Duration = .seconds(5)

    enum Cause: Equatable {
        case url(Int, host: String?)
        case http(Int)
        case signature
        case parse
        /// The feed download failed without a network error or status underneath.
        case download
        case other
    }

    static func chain(_ error: NSError) -> [NSError] {
        var all = [error]
        while all.count < 8, let next = all.last?.userInfo[NSUnderlyingErrorKey] as? NSError { all.append(next) }
        return all
    }

    // ponytail: Sparkle puts the HTTP status only in the message text, read it from the trailing "(404)"; use a
    // userInfo key if a later Sparkle adds one
    static func httpStatus(_ error: NSError) -> Int? {
        guard error.domain == sparkleDomain, error.code == downloadError else { return nil }
        let text = error.localizedDescription
        guard text.hasPrefix("A network error occurred while downloading"), text.hasSuffix(")"),
              let open = text.lastIndex(of: "(") else { return nil }
        return Int(text[text.index(after: open)..<text.index(before: text.endIndex)])
    }

    static func cause(_ error: NSError) -> Cause {
        let all = chain(error)
        if let url = all.first(where: { $0.domain == NSURLErrorDomain }) {
            return .url(url.code, host: (url.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host)
        }
        if let status = all.lazy.compactMap(httpStatus).first { return .http(status) }
        if all.contains(where: { $0.domain == sparkleDomain && [signatureError, validationError].contains($0.code) })
            || error.localizedDescription.contains("improperly signed") { return .signature }
        if all.contains(where: { $0.domain == sparkleDomain && [appcastParse, appcastError].contains($0.code) }) { return .parse }
        if all.contains(where: { $0.domain == sparkleDomain && $0.code == downloadError }) { return .download }
        return .other
    }

    /// A network error, a missing feed (a release swaps it for a moment) or a server error: one retry may succeed.
    public static func isTransient(_ error: NSError?) -> Bool {
        guard let error else { return false }
        switch cause(error) {
        case .url(let code, _): return code != NSURLErrorCancelled && !(-1206 ... -1200).contains(code)
        case .http(let status): return status == 404 || status == 408 || status == 429 || status >= 500
        case .download: return true
        case .signature, .parse, .other: return false
        }
    }

    /// One sentence a person can act on, for the toast, the Settings row and the menu alert.
    public static func describe(_ error: NSError?) -> String {
        guard let error else { return "The update check failed without saying why. Check again in a moment." }
        switch cause(error) {
        case .url(let code, let host):
            let server = host ?? "the update server"
            switch code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return "This Mac is offline. Connect to the internet and check again."
            case NSURLErrorTimedOut:
                return "\(server) did not answer in time. Check your connection and check again."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "Could not look up \(server). Check your connection or DNS settings."
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                return "The connection to \(server) failed. Check your connection and check again."
            case -1206 ... -1200:
                return "A secure connection to \(server) failed (error \(code)). Check the Mac's clock and any proxy or VPN."
            default:
                return "A network error stopped the update check: \(error.chainTail.localizedDescription) (error \(code))."
            }
        case .http(let status):
            let name = HTTPURLResponse.localizedString(forStatusCode: status)
            if status == 404 { return "The update feed was not found (HTTP 404). A release may be publishing; check again in a minute." }
            if status >= 500 { return "The update server returned an error for the feed (HTTP \(status), \(name)). Check again in a few minutes." }
            return "The update server refused the feed request (HTTP \(status), \(name))."
        case .signature:
            return "The update feed's signature does not match this app's key, so the app did not trust it. Install the latest release by hand from GitHub."
        case .parse:
            return "The update feed could not be read. It may be damaged; check again in a few minutes."
        case .download:
            let tail = error.chainTail
            return "The update feed could not be downloaded: \(tail.localizedDescription) (\(tail.domain) \(tail.code))."
        case .other:
            let tail = error.chainTail
            return "\(tail.localizedDescription) (\(tail.domain) \(tail.code))"
        }
    }
}

private extension NSError {
    var chainTail: NSError { UpdateCheckError.chain(self).last ?? self }
}
