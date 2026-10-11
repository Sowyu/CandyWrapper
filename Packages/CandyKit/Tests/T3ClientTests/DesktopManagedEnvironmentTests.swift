import Foundation
import Testing
import T3Protocol
@testable import T3Client

struct DesktopManagedEnvironmentTests {
    @Test func discoversOnlyConcreteNames() {
        #expect(SshEnvironmentDiscovery.aliases(config: "Host * !bad devbox web?\nHost=server # comment\nHost devbox") == ["devbox", "server"])
        #expect(SshEnvironmentDiscovery.knownHosts("|1|hashed key\n@cert-authority [host]:2222,other key\n*.wild key\n# comment") == ["host", "other"])
    }
    @Test func targetAndCommandSafety() throws {
        let target = try SshEnvironmentTarget.manual(host: " alice@[::1]:2222 ", username: "bob", port: "2200")
        #expect(target.alias == "::1" && target.username == "bob" && target.port == 2200)
        #expect(throws: (any Error).self) { try SshEnvironmentTarget(alias: "-oProxyCommand=evil") }
        #expect(throws: (any Error).self) { try SshEnvironmentTarget(alias: "host", username: "-oProxyCommand=evil") }
        #expect(throws: (any Error).self) { try SshEnvironmentTarget(alias: "two hosts") }
        let resolved = try SshEnvironmentTarget.resolved(alias: "devbox", output: "hostname example.invalid\nuser first\nuser ignored\nport 2222\n")
        #expect(resolved.hostname == "example.invalid" && resolved.username == "first" && resolved.port == 2222)
        let args = try SshEnvironmentCommand.tunnel(resolved, localPort: 54321, remotePort: 3773, interactive: true)
        #expect(args.suffix(5) == ["-n", "-N", "-L", "54321:127.0.0.1:3773", "first@devbox"])
        #expect(args.contains("ControlPath=none") && args.contains("ExitOnForwardFailure=yes") && args.contains("BatchMode=no"))
        #expect(SshEnvironmentCommand.launch(resolved, interactive: false).suffix(5) == ["sh", "-l", "-s", "--", resolved.stateKey])
        #expect(try SshEnvironmentCommand.resolve("devbox").suffix(2) == ["-G", "devbox"])
    }
    @Test func scriptsArePinnedQuotedAndNotExecuted() throws {
        let target = try SshEnvironmentTarget(alias: "fixture")
        let scripts = try SshEnvironmentCommand.scripts(version: "0.0.46-nightly.20261009.2861", stateKey: target.stateKey)
        for text in [scripts.launch, scripts.pairing, scripts.stop] { #expect(!text.contains("@@T3_")) }
        #expect(scripts.launch.contains("__ssh-helper wait-ready"))
        #expect(scripts.launch.contains("SHA256SUMS"))
        #expect(scripts.launch.contains("T3_ARCHIVE_VERSION='0.0.46-nightly.20261009.2861'"))
        // Nested scripts lose their trailing newlines, so each heredoc body ends right before its terminator.
        #expect(!scripts.launch.contains("\n\nSH\n"))
        #expect(!scripts.pairing.contains("\n\nSH\n"))
        #expect(scripts.pairing.contains("auth pairing create --base-dir"))
        #expect(scripts.stop.contains("external"))
        #expect(throws: (any Error).self) { try SshEnvironmentCommand.scripts(version: "x';touch evil", stateKey: target.stateKey) }
        #expect(throws: (any Error).self) { try SshEnvironmentCommand.scripts(version: "1.2.3", stateKey: "../../bad") }
        #expect(throws: (any Error).self) { try SshEnvironmentCommand.scripts(version: "01.2.3", stateKey: target.stateKey) }
    }
    @Test func askpassDoesNotPersistSecretOrInheritLiveContext() {
        let env = SshEnvironmentCommand.childEnvironment(base: ["T3CODE_HOME": "live", "T3_SERVICE_LAUNCHER_CONTEXT": "live", "SSH_AUTH_SOCK": "agent", "SSH_ASKPASS": "wrong", "HOME": "/fixture"], helper: "/fixture/helper", password: "fixture-secret")
        #expect(env["T3CODE_HOME"] == nil && env["T3_SERVICE_LAUNCHER_CONTEXT"] == nil)
        #expect(env["SSH_AUTH_SOCK"] == "agent")
        #expect(env["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(env["T3_SSH_AUTH_SECRET"] == "fixture-secret")
        #expect(!SshEnvironmentCommand.askpassScript.contains("fixture-secret"))
        #expect(!SshEnvironmentCommand.diagnostic(#"{"credential":"secret","token":"secret"}"#).contains("secret"))
        #expect(SshEnvironmentError("Permission denied (publickey,password).").isAuthenticationFailure)
        #expect(!SshEnvironmentError("Host key verification failed.").isAuthenticationFailure)
    }
    @Test func bootstrapParsingAndErrors() throws {
        struct Pair: Decodable { let credential: String }
        #expect(try SshEnvironmentCommand.lastJSON("login banner\n{\"credential\":\"fixture\"}\n", as: Pair.self).credential == "fixture")
        #expect(throws: (any Error).self) { try SshEnvironmentCommand.lastJSON("banner only", as: Pair.self) }
        #expect(SshEnvironmentCommand.failureMessage(stdout: "", stderr: " denied \n", destination: "a@b", status: 255) == "denied")
        #expect(SshEnvironmentCommand.failureMessage(stdout: #"{"token":"s3cret"}"#, stderr: "", destination: "a@b", status: 1) == #"{"token":"[redacted]"}"#)
        #expect(SshEnvironmentCommand.failureMessage(stdout: "", stderr: "", destination: "a@b", status: 7) == "SSH command failed for a@b (exit 7).")
    }
    /// parseManualDesktopSshTarget, formatDesktopSshTarget and the `ssh -G` merge.
    @Test func manualTargetsLabelsAndMerge() throws {
        let inline = try SshEnvironmentTarget.manual(host: "alice@devbox:2222", username: "", port: "")
        #expect(inline.alias == "devbox" && inline.username == "alice" && inline.port == 2222)
        #expect(try SshEnvironmentTarget.manual(host: "[fe80::1]", username: "", port: "").alias == "fe80::1")
        #expect(try SshEnvironmentTarget.manual(host: "box", username: "", port: "22junk").port == 22)
        #expect(throws: (any Error).self) { try SshEnvironmentTarget.manual(host: "  ", username: "", port: "") }
        #expect(throws: (any Error).self) { try SshEnvironmentTarget.manual(host: "box", username: "", port: "70000") }
        #expect(throws: (any Error).self) { try SshEnvironmentTarget.manual(host: "box", username: "", port: "x") }
        // A leading `@` is not a user separator (atIndex > 0).
        #expect(try SshEnvironmentTarget.manual(host: "@box", username: "", port: "").alias == "@box")
        let resolved = try SshEnvironmentTarget.resolved(alias: "devbox", output: "hostname 10.0.0.5\nuser mrm\nport 22\n")
        let merged = inline.merging(resolved: resolved)
        #expect(merged.alias == "devbox" && merged.hostname == "10.0.0.5" && merged.username == "alice" && merged.port == 2222)
        #expect(merged.display == "alice@10.0.0.5:2222" && merged.routeLabel == "SSH alice@10.0.0.5")
        #expect(try SshEnvironmentTarget(alias: "box").merging(resolved: resolved).username == "mrm")
        // remoteStateKey: SHA-256 of `alias\0hostname\0user\0port`, first 16 hex characters.
        #expect(try SshEnvironmentTarget(alias: "devbox", hostname: "devbox").stateKey == "6a175896758606e2")
    }
    @Test func relayStatusMessages() throws {
        let status = try JSONDecoder().decode(RelayClientInstallStatus.self, from: Data(#"{"status":"unsupported","platform":"linux","arch":"riscv64","version":"1"}"#.utf8))
        #expect(status.unsupportedMessage == "T3 Code cannot install the relay client automatically on linux-riscv64.")
        let event = try JSONDecoder().decode(RelayClientInstallEvent.self, from: Data(#"{"type":"progress","stage":"waiting_for_lock"}"#.utf8))
        #expect(event.stage == .waitingForLock && event.stage?.step == 2)
    }
}
