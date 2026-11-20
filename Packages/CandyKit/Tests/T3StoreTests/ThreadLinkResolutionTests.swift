import Testing
import T3Protocol
@testable import T3Store

struct ThreadLinkResolutionTests {

    @Test func scopedLinksNeverGuessAndV1RequiresAUniqueRemoteMatch() throws {
        let a = thread("one:same"), b = thread("two:same")
        func resolve(_ href: String, threads: [ThreadShell]) throws -> ThreadId? {
            ThreadLinkResolution.resolve(try #require(ThreadLink(href: href)), messageEnvironmentId: "local", threads: threads)?.id
        }
        #expect(try resolve("t3-thread://v2/local/same", threads: [a]) == nil)
        #expect(try resolve("t3-thread://v2/two/same", threads: [a, b]) == b.id)
        #expect(try resolve("t3-thread://v1/same", threads: [a]) == a.id)
        #expect(try resolve("t3-thread://v1/same", threads: [a, b]) == nil)
        let local = thread("local:same")
        #expect(try resolve("t3-thread://v1/same", threads: [a, b, local]) == local.id)
    }

    @Test func decodedLocalIdWinsOverAWrittenRemoteMatch() throws {
        let local = thread("local:a b"), remote = thread("remote:a%20b")
        let link = try #require(ThreadLink(href: "t3-thread://v1/a%20b"))
        #expect(ThreadLinkResolution.resolve(link, messageEnvironmentId: "local", threads: [remote, local])?.id == local.id)
    }
}
