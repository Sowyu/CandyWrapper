import Foundation
import Testing
@testable import T3Store

/// What a client types to install or remove the helper, and how it reads the terminal back.
@Suite struct HelperInstallTests {
    let release = HelperInstall.Release(version: "1.14.0", baseURL: URL(string: "https://github.com/Sowyu/CandyWrapper/releases/download/v1.14.0")!,
                                        sums: ["darwin-universal": "aa", "linux-x86_64": "bb", "linux-aarch64": "cc"])

    /// The terminal echoes the typed line, which must never read as a result.
    @Test func theEchoedCommandCarriesNoMarker() {
        let command = HelperInstall.installCommand(release, homeId: "env-a")
        #expect(HelperInstall.scan(command).isEmpty)
        #expect(HelperInstall.scan(HelperInstall.uninstallCommand()).isEmpty)
    }

    @Test func readsMarkersThroughColoursAndCarriageReturns() {
        let output = "% sh -c '…'\r\n\u{1B}[0mCWH-READY\r\npaired miniko\r\nCWH-WARNING Lingering is off\r\n\u{1B}[1mCWH-RESULT ok 1.14.0 loopback http://127.0.0.1:3773\u{1B}[0m\r\n"
        #expect(HelperInstall.scan(output) == [.ready, .warning("Lingering is off"), .ok("1.14.0 loopback http://127.0.0.1:3773")])
        #expect(HelperInstall.scan("CWH-RESULT failed the checksum of the download did not match\n") == [.failed("the checksum of the download did not match")])
    }

    @Test func theSessionLabelCarriesTheVersion() {
        let label = HelperInstall.sessionLabel(version: "1.14.0", home: "miniko")
        #expect(HelperInstall.version(fromSessionLabel: label) == "1.14.0")
        #expect(HelperInstall.version(fromSessionLabel: "CandyWrapper on MacBook") == nil)
    }

    @Test func noValueCanBreakOutOfTheQuotes() {
        let command = HelperInstall.installCommand(release, homeId: "env'; rm -rf ~; '")
        let body = command.dropFirst(" sh -c '".count).dropLast("'\n".count)
        #expect(!body.contains("'"))
        #expect(HelperInstall.pairingInput([.init(machineId: "a", label: "Mac\tmini", url: URL(string: "http://127.0.0.1:1")!, code: "C")]) == "a\tMac mini\thttp://127.0.0.1:1\tC\n.\n")
    }

    /// Both commands parse as POSIX sh.
    @Test func theCommandsAreValidShell() throws {
        for command in [HelperInstall.installCommand(release, homeId: "env-a", testHome: "/tmp/x y"), HelperInstall.uninstallCommand()] {
            let body = String(command.dropFirst(" sh -c '".count).dropLast("'\n".count))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", "-c", body]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}
