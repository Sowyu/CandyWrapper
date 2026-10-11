import Foundation
import Testing
import T3Protocol
@testable import Features

/// Load balancing preferences, against LoadBalancingSettings.test.ts.
struct LoadBalancingTests {
    @Test func snapsLegacySliderWeights() {
        #expect(LoadBalancingLogic.preference(forWeight: nil) == 50)
        #expect(LoadBalancingLogic.preference(forWeight: 0) == 0)
        #expect(LoadBalancingLogic.preference(forWeight: 10) == 25)
        #expect(LoadBalancingLogic.preference(forWeight: 50) == 50)
        #expect(LoadBalancingLogic.preference(forWeight: 80) == 100)
    }

    @Test func summaryListsMachinesOffNormalInOrder() {
        let machines = [(id: "a", label: "alvin"), (id: "b", label: "bb-1"), (id: "c", label: "ProMini")]
        #expect(LoadBalancingLogic.summary(machines, weights: ["a": 50]) == nil)
        #expect(LoadBalancingLogic.summary(machines, weights: ["b": 100, "c": 0]) == "bb-1 prefer · ProMini manual only")
    }

    @Test func storedWeightsDropInvalidEntries() {
        let json: JSONValue = .object(["a": .number(100), "b": .number(140), "c": .string("x"), "d": .number(25)])
        #expect(LoadBalancingLogic.weights(json) == ["a": 100, "d": 25])
        let off = ConnectionsPageModel.LoadBalancing(enabled: false, machines: [], weights: [:])
        #expect(off.summary == "Off")
    }
}
