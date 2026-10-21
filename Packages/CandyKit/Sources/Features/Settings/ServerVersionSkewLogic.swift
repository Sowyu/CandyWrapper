import Foundation
import T3Protocol

/// apps/web/src/versionSkew.ts:46-108, 131-143. A newer server is not an update warning.
public enum ServerVersionSkewLogic {
    /// The official source version this client implements; update with T3_VERSION. A Debug build takes
    /// `--t3-client-version <version>`, so a sandbox server can be updated to a newer runtime.
    public static let clientVersion: String = {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--t3-client-version"), i + 1 < args.count { return args[i + 1] }
        #endif
        return "0.1.2-nightly.20261021.3473"
    }()
    public static let hint = "Version mismatch. Try syncing the client and server to the same T3 Code version."
    private struct Version {
        let core: [Int], pre: [String]
        init?(_ input: String) {
            let value = input.hasPrefix("v") ? String(input.dropFirst()) : input
            let noBuild = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let parts = noBuild.split(separator: "-", maxSplits: 1)
            guard let first = parts.first else { return nil }
            let numbers = first.split(separator: ".")
            guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), numbers.compactMap({ Int($0) }).count == 3 else { return nil }
            core = numbers.compactMap { Int($0) }; pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        }
    }
    public static func serverIsBehind(_ server: String?, client: String = clientVersion) -> Bool {
        guard let server = server?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty, !client.isEmpty else { return false }
        guard let a = Version(server), let b = Version(client) else { return server != client }
        for (x, y) in zip(a.core, b.core) where x != y { return x < y }
        guard a.pre.first == "nightly", b.pre.first == "nightly" else { return false }
        for (x, y) in zip(a.pre, b.pre) where x != y {
            if let nx = Int(x), let ny = Int(y) { return nx < ny }
            if Int(x) != nil { return true }; if Int(y) != nil { return false }; return x < y
        }
        return a.pre.count < b.pre.count
    }
    public static func manualCommand(target: String = clientVersion, installation: JSONValue? = nil) -> String {
        let kind = installation?["kind"]?.stringValue
        if kind == "npm-global", let prefix = installation?["prefix"]?.stringValue {
            return "npm install --global --prefix '" + prefix.replacingOccurrences(of: "'", with: "'\\''") + "' t3@" + target
        }
        let runner = kind == "pnpm-dlx" ? "pnpm dlx" : kind == "bunx" ? "bunx" : "npx"
        return runner + " t3@" + target
    }
}
