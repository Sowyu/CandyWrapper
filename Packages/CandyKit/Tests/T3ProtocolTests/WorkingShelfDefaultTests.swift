import Testing
@testable import T3Protocol

struct WorkingShelfDefaultTests {
    @Test func absentPreferenceUsesWorkingShelfAndExplicitChoicesSurvive() {
        #expect(ClientSettings(decoding: nil).bool("sidebarWorkingShelfEnabled"))
        #expect(ClientSettings(decoding: .object([:])).bool("sidebarWorkingShelfEnabled"))
        #expect(!ClientSettings(decoding: .object(["sidebarWorkingShelfEnabled": .bool(false)])).bool("sidebarWorkingShelfEnabled"))
        #expect(ClientSettings(decoding: .object(["sidebarWorkingShelfEnabled": .bool(true)])).bool("sidebarWorkingShelfEnabled"))
    }
}
