import Foundation
import T3Store
#if canImport(Security)
import Security
#endif

/// The `VERSION` file the release puts next to the binary; "dev" in a plain build.
let helperVersion: String = {
    let file = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "VERSION")
    let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? "dev" : text
}()

#if os(Linux)
let helperOS = "Linux"
#else
let helperOS = "macOS"
#endif

/// A machine the helper reaches, as the install handed it over. Holds no secret.
struct HelperMachine: Codable, Equatable, Sendable {
    var id: String
    var label: String
    /// The URL CandyWrapper reaches it at: a direct address or its T3 Connect tunnel.
    var url: URL
    /// The machine the helper runs on, where the Orchestrator thread lives.
    var isHome: Bool
    /// The home server's own loopback address, tried first.
    var loopbackURL: URL?
}

/// What the helper remembers between runs, beside the relay settings it reads from the server.
struct HelperMemory: Codable, Equatable, Sendable {
    /// When the helper last prompted each thread, scoped id to epoch ms, for the ask-first rule.
    var relayedAt: [String: Int64] = [:]
    /// Scoped ids of the workers it launched, which count toward the worker limit.
    var relayWorkers: Set<String> = []
}

/// The helper's folder: `~/Library/Application Support/CandyWrapper Helper` on macOS, `~/.config/candywrapper-helper`
/// on Linux, or `CANDY_HELPER_HOME`.
enum HelperStore {
    static let home: URL = {
        if let custom = ProcessInfo.processInfo.environment["CANDY_HELPER_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        #if os(Linux)
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        return config.appending(path: "candywrapper-helper", directoryHint: .isDirectory)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/CandyWrapper Helper", directoryHint: .isDirectory)
        #endif
    }()

    static var isCustomHome: Bool { ProcessInfo.processInfo.environment["CANDY_HELPER_HOME"].map { !$0.isEmpty } ?? false }

    static func ensureHome() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }

    static func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: home.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Written whole and renamed into place, readable only by this user.
    static func write(_ name: String, _ value: some Encodable) throws {
        try ensureHome()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try CacheFile.write(try encoder.encode(value), to: home.appending(path: name))
    }

    static var machines: [HelperMachine] { read("machines.json", as: [HelperMachine].self) ?? [] }
    static var memory: HelperMemory { read("memory.json", as: HelperMemory.self) ?? HelperMemory() }
}

/// The helper's bearer tokens, one per machine id. The macOS login Keychain, or a 0600 file on Linux, which usually has
/// no secret service; encrypting the file with a key kept beside it would protect nothing. Tokens never reach a log.
enum HelperSecrets {
    static func save(_ token: String, for id: String) throws { try useFile ? FileSecrets.save(token, for: id) : KeychainSecrets.save(token, for: id) }
    static func load(_ id: String) -> String? { useFile ? FileSecrets.load(id) : KeychainSecrets.load(id) }
    static func remove(_ id: String) { useFile ? FileSecrets.remove(id) : KeychainSecrets.remove(id) }
    static func removeAll() { useFile ? FileSecrets.removeAll() : KeychainSecrets.removeAll() }

    /// Linux, and test runs with `CANDY_HELPER_HOME`: an unsigned dev build gets a new signature each build, and
    /// macOS then asks for the login password before it reads the last build's Keychain item, which blocks a daemon.
    private static var useFile: Bool {
        #if canImport(Security)
        HelperStore.isCustomHome
        #else
        true
        #endif
    }
}

#if canImport(Security)
private enum KeychainSecrets {
    private static let service = "CandyWrapper Helper"

    static func save(_ token: String, for id: String) throws {
        remove(id)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id,
                                     kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecValueData: Data(token.utf8)]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw HelperError("the Keychain refused the token (\(status))") }
    }

    static func load(_ id: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ id: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id] as CFDictionary)
    }

    static func removeAll() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}
#else
private enum KeychainSecrets {
    static func save(_ token: String, for id: String) throws {}
    static func load(_ id: String) -> String? { nil }
    static func remove(_ id: String) {}
    static func removeAll() {}
}
#endif

private enum FileSecrets {
    private static var all: [String: String] { HelperStore.read("credentials.json", as: [String: String].self) ?? [:] }

    static func save(_ token: String, for id: String) throws {
        var tokens = all
        tokens[id] = token
        try HelperStore.write("credentials.json", tokens)
    }

    static func load(_ id: String) -> String? { all[id] }

    static func remove(_ id: String) {
        var tokens = all
        tokens[id] = nil
        try? HelperStore.write("credentials.json", tokens)
    }

    static func removeAll() { try? FileManager.default.removeItem(at: HelperStore.home.appending(path: "credentials.json")) }
}

struct HelperError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One line on stderr, which launchd and journald keep. Callers pass labels, call names and error text, never tokens.
func log(_ text: String) {
    FileHandle.standardError.write(Data("\(Date().ISO8601Format()) \(text)\n".utf8))
}
