import Testing
import T3Protocol
import T3Store
@testable import Features

struct FxProviderTests {
    @Test func fxRequiresServerAdvertisementAndKeepsServerModelIDs() {
        let fx = ServerProvider(instanceId: .init("fx_custom"), driver: "fx")
        #expect(!ProvidersLogic.addableDrivers(providers: []).contains { $0.driver == "fx" })
        #expect(ProvidersLogic.addableDrivers(providers: [fx]).contains { $0.driver == "fx" })
        #expect(ProvidersLogic.label("fx") == "fx")
        let settings = ServerSettingsValues(.object([:]))
        #expect(!ProvidersLogic.rows(settings: settings, providers: []).contains { $0.driver == "fx" })
        #expect(ProvidersLogic.rows(settings: settings, providers: [fx], target: "fx").contains { $0.driver == "fx" })
        let fields = ProvidersLogic.fields("fx")
        #expect(fields.count == 1)
        #expect(fields.first?.key == "binaryPath")
        #expect(fields.first?.placeholder == "fx")
        let payload = ProviderSetupLogic.create(id: "fx_custom", driver: "fx", label: "fx", config: ["binaryPath": .string("/opt/bin/fx")])
        #expect(payload["providerInstanceMutation"]?["instance"]?["driver"] == .string("fx"))
        #expect(payload["providerInstanceMutation"]?["instance"]?["config"]?["binaryPath"] == .string("/opt/bin/fx"))
        #expect(payload["providerInstanceMutation"]?["instance"]?["config"]?["setupMode"] == nil)
    }
}
