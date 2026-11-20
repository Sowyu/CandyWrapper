import Foundation
import Testing
@testable import T3Store

/// What a client types to remove an old relay helper, and how it reads the terminal back.
@Suite struct HelperInstallTests {
    /// A result line split across output chunks still reads as one marker.
    @Test func aMarkerSurvivesEveryChunkSize() {
        let output = "$ sh -c '…'\r\n\u{1B}[0mstopped the service\r\nCWH-RESULT ok removed\r\n$ "
        for width in [1, 7, 4_096] {
            var reader = HelperInstall.MarkerReader()
            var rest = Substring(output)
            while !rest.isEmpty { reader.append(String(rest.prefix(width))); rest = rest.dropFirst(width) }
            #expect(reader.started)
            #expect(reader.lines == [.ok("removed")], "chunk width \(width)")
        }
    }

    /// The terminal echoes the typed line, which must never read as a result.
    @Test func theEchoedCommandCarriesNoMarker() {
        #expect(HelperInstall.scan(HelperInstall.uninstallCommand()).isEmpty)
    }

    @Test func readsMarkersThroughColoursAndCarriageReturns() {
        let output = "% sh -c '…'\r\n\u{1B}[0mstopped com.sowyu.candywrapper.helper\r\n\u{1B}[1mCWH-RESULT ok removed\u{1B}[0m\r\n"
        #expect(HelperInstall.scan(output) == [.ok("removed")])
        #expect(HelperInstall.scan("CWH-RESULT failed launchctl bootout returned 5\n") == [.failed("launchctl bootout returned 5")])
    }

    @Test func theSessionLabelCarriesTheVersion() {
        let label = HelperInstall.sessionLabel(version: "1.14.0", home: "miniko")
        #expect(HelperInstall.version(fromSessionLabel: label) == "1.14.0")
        #expect(HelperInstall.version(fromSessionLabel: "CandyWrapper on MacBook") == nil)
    }

    /// The uninstall line parses as POSIX sh, with or without a test home.
    @Test func theCommandsAreValidShell() throws {
        for command in [HelperInstall.uninstallCommand(testHome: "/tmp/x y"), HelperInstall.uninstallCommand()] {
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
