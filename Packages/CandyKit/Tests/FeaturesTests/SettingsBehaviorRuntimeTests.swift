import Foundation
import Testing
@testable import Features
import T3Protocol

struct SettingsBehaviorRuntimeTests {
    @Test func importRejectsWholeInvalidFileAndExistingActions() {
        let file = #"{scripts:[{name:'Build',command:'make',runOnWorktreeCreate:true,async:false},{name:'Test',command:'test'}]}"#
        let scripts = ProjectActionsLogic.importableScripts(file, existing: [ProjectScript(id: "a", name: "build", command: "other")])
        #expect(scripts.map(\.name) == ["Test"])
        let setup = ProjectActionsLogic.importableScripts(file, existing: []).first
        #expect(setup?.waitForSetup == true)
        #expect(ProjectActionsLogic.importableScripts(#"{"scripts":[{"name":"ok","command":"ok"},{"name":"bad","command":""}]}"#, existing: []).isEmpty)
        #expect(ProjectActionsLogic.importableScripts(#"{"worktreeSubmodules":"wrong","scripts":[{"name":"ok","command":"ok"}]}"#, existing: []).isEmpty)
    }
    @Test func chartZeroAndTinySamples() {
        #expect(SettingsResourceHistoryChart.fraction(0, maximum: 100) == 0)
        #expect(SettingsResourceHistoryChart.fraction(0.01, maximum: 100) == 0.01)
        #expect(SettingsResourceHistoryChart.fraction(50, maximum: 100) == 0.5)
        #expect(SettingsResourceHistoryChart.fraction(.nan, maximum: 100) == 0)
    }
    @Test func licenseSchemaAndSearch() throws {
        let entry = #"{"kind":"package","name":"Example","version":"1.0","license":"MIT","noticeText":"Notice","bundles":["web"],"sourceUrl":"https://example.com"}"#
        let manifest = try SettingsLicenseManifest.parse(Data("{\"schemaVersion\":1,\"entries\":[\(entry)]}".utf8))
        #expect(manifest.entries[0].matches("mit WEB"))
        #expect(!manifest.entries[0].matches("mit server"))
        #expect(throws: (any Error).self) { try SettingsLicenseManifest.parse(Data("{\"schemaVersion\":1,\"entries\":[\(entry),\(entry)]}".utf8)) }
    }
    @Test func proactiveDefersAndRespectsUserChoice() {
        var state = SettingsProactivePanels()
        func update(_ run: String?, _ revision: Int, _ status: String?) -> SettingsProactivePanels.Action {
            state.update(thread: "t", running: run, settled: "r", completed: run == nil, linkedTarget: nil,
                         revision: revision, enabled: true, checkpointStatus: status, fileCount: 3, changedLines: 2, isRepository: true, activeSurface: nil)
        }
        #expect(update("r", 0, nil) == .none)
        #expect(update(nil, 0, nil) == .none)
        #expect(update(nil, 0, "ready") == .diff)
        #expect(update(nil, 0, "ready") == .none)
        state = SettingsProactivePanels()
        #expect(update("r", 0, nil) == .none)
        #expect(update(nil, 1, "ready") == .none)
    }
}
