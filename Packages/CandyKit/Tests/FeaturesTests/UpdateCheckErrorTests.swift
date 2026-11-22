import Foundation
import Testing
@testable import Features

/// Sparkle 2.10.0's feed errors, built the way SUAppcastDriver.m and SPUDownloader.m build them.
struct UpdateCheckErrorTests {
    typealias E = UpdateCheckError
    static let feed = "https://github.com/Sowyu/CandyWrapper/releases/download/appcast/appcast.xml"

    static func sparkle(_ code: Int, _ text: String, under: NSError? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: text]
        if let under { info[NSUnderlyingErrorKey] = under }
        return NSError(domain: "SUSparkleErrorDomain", code: code, userInfo: info)
    }
    /// `downloadDriverDidFailToFetchAppcast`'s wrapper, the text of the user's toast.
    static func fetchFailed(_ under: NSError) -> NSError {
        sparkle(2001, "An error occurred in retrieving update information. Please try again later.", under: under)
    }
    static func http(_ status: Int) -> NSError {
        fetchFailed(sparkle(2001, "A network error occurred while downloading \(feed). \(HTTPURLResponse.localizedString(forStatusCode: status)) (\(status))"))
    }
    static func url(_ code: Int) -> NSError {
        let u = NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: feed)!,
                                                                         NSLocalizedDescriptionKey: "url error \(code)"])
        return fetchFailed(sparkle(2001, "Failed to download temporary data.", under: u))
    }

    @Test func httpStatusesAreNamedAndOnlyTransientOnesRetry() {
        #expect(E.describe(Self.http(404)) == "The update feed was not found (HTTP 404). A release may be publishing; check again in a minute.")
        #expect(E.describe(Self.http(503)).hasPrefix("The update server returned an error for the feed (HTTP 503"))
        #expect(E.describe(Self.http(403)).hasPrefix("The update server refused the feed request (HTTP 403"))
        #expect(E.isTransient(Self.http(404)) && E.isTransient(Self.http(502)) && E.isTransient(Self.http(429)))
        #expect(!E.isTransient(Self.http(403)) && !E.isTransient(Self.http(401)))
    }

    @Test func networkErrorsNameTheHostAndRetry() {
        #expect(E.describe(Self.url(NSURLErrorNotConnectedToInternet)) == "This Mac is offline. Connect to the internet and check again.")
        #expect(E.describe(Self.url(NSURLErrorTimedOut)) == "github.com did not answer in time. Check your connection and check again.")
        #expect(E.describe(Self.url(NSURLErrorCannotFindHost)) == "Could not look up github.com. Check your connection or DNS settings.")
        #expect(E.describe(Self.url(NSURLErrorNetworkConnectionLost)) == "The connection to github.com failed. Check your connection and check again.")
        #expect(E.describe(Self.url(NSURLErrorServerCertificateUntrusted)).contains("error -1202"))
        #expect(E.describe(Self.url(NSURLErrorBadServerResponse)) == "A network error stopped the update check: url error -1011 (error -1011).")
        #expect(E.isTransient(Self.url(NSURLErrorTimedOut)) && E.isTransient(Self.url(NSURLErrorNetworkConnectionLost)))
        #expect(!E.isTransient(Self.url(NSURLErrorServerCertificateUntrusted)) && !E.isTransient(Self.url(NSURLErrorCancelled)))
    }

    @Test func signatureParseAndUnknownErrorsDoNotRetry() {
        let signed = Self.sparkle(1000, "The update feed is improperly signed and could not be validated. Please try again later or contact the app developer.",
                                  under: Self.sparkle(3002, "EdDSA signature does not match"))
        #expect(E.describe(signed).hasPrefix("The update feed's signature does not match this app's key"))
        let parse = Self.sparkle(1000, "An error occurred while parsing the update feed.")
        #expect(E.describe(parse) == "The update feed could not be read. It may be damaged; check again in a few minutes.")
        #expect(!E.isTransient(signed) && !E.isTransient(parse) && !E.isTransient(nil))
        let odd = NSError(domain: "Other", code: 7, userInfo: [NSLocalizedDescriptionKey: "Odd."])
        #expect(E.describe(odd) == "Odd. (Other 7)")
        // A fetch that failed with nothing underneath still names Sparkle's inner reason and retries.
        let bare = Self.fetchFailed(Self.sparkle(2001, "Failed to download temporary data."))
        #expect(E.describe(bare) == "The update feed could not be downloaded: Failed to download temporary data. (SUSparkleErrorDomain 2001).")
        #expect(E.isTransient(bare))
    }

    @Test func noMessageSaysOnlyTryAgainLater() {
        for e in [Self.http(404), Self.http(500), Self.url(NSURLErrorTimedOut), Self.url(NSURLErrorNotConnectedToInternet)] {
            #expect(!E.describe(e).contains("try again later"))
        }
    }
}
