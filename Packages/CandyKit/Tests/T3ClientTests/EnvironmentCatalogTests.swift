import Foundation
import Testing
@testable import T3Client

struct EnvironmentCatalogTests {
    private func makeCatalog() -> (EnvironmentCatalog, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-catalog-\(UUID().uuidString)")
        let catalog = EnvironmentCatalog(file: dir.appending(path: "environments.json"),
                                         credentials: CredentialStore(service: "dev.candywrapper.t3.test-\(UUID().uuidString)"))
        return (catalog, dir)
    }

    private func keychainWorks(_ store: CredentialStore) -> Bool {
        do { try store.save(token: "probe", environmentId: "probe"); try store.delete(environmentId: "probe"); return true } catch {
            // A locked keychain with no GUI login can't be written. Not a code failure.
            print("keychain unavailable, skipping: \(error)")
            return false
        }
    }

    @Test func addPersistsWithoutSecretsAndRemoveForgetsTheToken() throws {
        let (catalog, dir) = makeCatalog()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard keychainWorks(catalog.credentials) else { return }
        #expect(catalog.load().isEmpty)
        let a = EnvironmentRegistration(environmentId: "env-a", label: "Studio", httpBaseURL: URL(string: "http://10.0.0.2:3773")!,
                                        machine: "mac-studio", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let b = EnvironmentRegistration(environmentId: "env-b", label: "Box", httpBaseURL: URL(string: "https://box.example")!,
                                        createdAt: Date(timeIntervalSince1970: 1_800_000_100))
        try catalog.add(a, token: "secret-a")
        try catalog.add(b, token: "secret-b")
        defer { try? catalog.remove(environmentId: "env-a"); try? catalog.remove(environmentId: "env-b") }

        // A fresh catalog on the same file reads the same registrations, in order.
        let reread = EnvironmentCatalog(file: catalog.file, credentials: catalog.credentials).load()
        #expect(reread == [a, b])
        // The document holds no token.
        let text = try String(contentsOf: catalog.file, encoding: .utf8)
        #expect(!text.contains("secret"))
        #expect(try catalog.token(environmentId: "env-a") == "secret-a")
        let mode = try FileManager.default.attributesOfItem(atPath: catalog.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        // Same id again replaces in place, token too.
        var renamed = a
        renamed.label = "Studio 2"
        try catalog.add(renamed, token: "secret-a2")
        #expect(catalog.load().map(\.label) == ["Studio 2", "Box"])
        #expect(try catalog.token(environmentId: "env-a") == "secret-a2")

        // Pairing env-a again over another address adds a route, LAN ahead of a public name, and
        // keeps the switch; the route has its own token.
        try catalog.setEnabled(false, environmentId: "env-a")
        let tailnet = URL(string: "https://studio.tail1234.ts.net/")!
        var again = EnvironmentRegistration(environmentId: "env-a", label: "Studio 2", httpBaseURL: tailnet)
        try catalog.add(again, token: "secret-a-tailnet")
        again.httpBaseURL = URL(string: "https://studio.example.com/")!
        try catalog.add(again, token: "secret-a-public")
        #expect(catalog.load()[0].routes.map(EnvironmentRoute.origin) == ["http://10.0.0.2:3773", "https://studio.tail1234.ts.net", "https://studio.example.com"])
        #expect(catalog.load()[0].enabled == false)

        // A dragged order is saved as is; a different set of routes is refused.
        let dragged = [URL(string: "https://studio.example.com/")!, URL(string: "http://10.0.0.2:3773")!, tailnet]
        try catalog.reorderRoutes(dragged, environmentId: "env-a")
        #expect(catalog.load()[0].routes.map(EnvironmentRoute.origin) == ["https://studio.example.com", "http://10.0.0.2:3773", "https://studio.tail1234.ts.net"])
        #expect(try catalog.reorderRoutes(Array(dragged.prefix(2)), environmentId: "env-a") == nil)
        #expect(try catalog.token(environmentId: "env-a") == "secret-a-public")
        try catalog.reorderRoutes([dragged[1], tailnet, dragged[0]], environmentId: "env-a")
        #expect(try catalog.token(environmentId: "env-a", route: tailnet) == "secret-a-tailnet")
        #expect(try catalog.token(environmentId: "env-a") == "secret-a2")
        try catalog.removeRoute(tailnet, environmentId: "env-a")
        #expect(catalog.load()[0].routes.count == 2)
        #expect(try catalog.token(environmentId: "env-a", route: tailnet) == nil)
        try catalog.setEnabled(true, environmentId: "env-a")

        try catalog.setEnabled(false, environmentId: "env-b")
        #expect(catalog.load().map(\.enabled) == [true, false])

        try catalog.remove(environmentId: "env-a")
        #expect(catalog.load().map(\.environmentId) == ["env-b"])
        #expect(try catalog.token(environmentId: "env-a") == nil)
        #expect(try catalog.credentials.load(environmentId: EnvironmentRoute.connectionId(environmentId: "env-a", again.httpBaseURL)) == nil)
    }

    @Test func corruptDocumentIsMovedAside() throws {
        let (catalog, dir) = makeCatalog()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: catalog.file)
        #expect(catalog.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: catalog.file.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("environments.corrupt-") })
    }
}
