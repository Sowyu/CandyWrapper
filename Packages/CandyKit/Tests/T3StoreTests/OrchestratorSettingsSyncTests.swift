import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The shared settings document (docs/orchestrator.md, "Settings on every device"): read, write, migration and two
/// devices editing at once, with last write wins per setting.
@Suite struct OrchestratorSettingsSyncTests {
    typealias Sync = OrchestratorSettingsSync

    func stamp(_ at: Int64, _ by: String) -> Sync.Stamp { .init(at: at, by: by) }

    /// The prompt as the Android app would write it.
    func document(_ json: String) throws -> Sync.Document {
        try #require(Sync.Document.parse(json))
    }

    @Test func readsTheDocumentIntoTheSettings() throws {
        let doc = try document("""
        {"format":"candywrapper.orchestrator-settings","version":1,"settings":{
          "name":{"value":"Ada","at":2000,"by":"phone"},
          "crewLimit":{"value":6,"at":2000,"by":"phone"},
          "closedCheckMinutes":{"value":null,"at":2000,"by":"phone"},
          "botShape":{"value":3,"at":2000,"by":"phone"},
          "handsOff":{"value":["env-a:t2","env-a:t1"],"at":2000,"by":"phone"},
          "notebook.rules":{"value":"Ask before merging.","at":2000,"by":"phone"},
          "models":{"value":[{"id":"cheap","label":"Cheap","instanceId":"claudeAgent","model":"claude-sonnet-5-5",
            "options":[{"id":"effort","value":"medium"}],"useWhen":"Docs","notes":"","isDefault":true}],"at":2000,"by":"phone"}
        }}
        """)
        let m = Sync.merge(config: OrchestratorConfig(), stamps: [:], documents: [doc], machine: "env-a")
        #expect(m.config.name == "Ada")
        #expect(m.config.crewLimit == 6)
        #expect(m.config.closedCheckMinutes == nil)
        #expect(m.config.botShape == 3)
        #expect(m.config.handsOff == ["env-a:t1", "env-a:t2"])
        #expect(m.config.notebook["rules"] == "Ask before merging.")
        #expect(m.config.models.map(\.model) == ["claude-sonnet-5-5"])
        #expect(m.config.models.first?.options.first?.value == .string("medium"))
        #expect(m.stamps["name"] == stamp(2000, "phone"))
        // Nothing of this Mac's is newer, so nothing goes back.
        #expect(m.write == nil)
    }

    /// A null machine is the machine the document lives on, never this device's primary.
    @Test func aNullMachineIsTheDocumentsOwn() throws {
        let doc = try document(#"{"format":"candywrapper.orchestrator-settings","version":1,"settings":{"environmentId":{"value":null,"at":5,"by":"phone"}}}"#)
        #expect(Sync.merge(config: OrchestratorConfig(), stamps: [:], documents: [doc], machine: "env-b").config.environmentId == "env-b")
    }

    @Test func wrongTypesAndBadCountsAreIgnored() throws {
        let doc = try document("""
        {"format":"candywrapper.orchestrator-settings","version":1,"settings":{
          "name":{"value":7,"at":9,"by":"phone"},"crewLimit":{"value":0,"at":9,"by":"phone"},
          "notebook.plan":{"value":["x"],"at":9,"by":"phone"},"askFirstMinutes":{"value":15,"at":9,"by":"phone"}
        }}
        """)
        let m = Sync.merge(config: OrchestratorConfig(), stamps: [:], documents: [doc], machine: "env-a")
        #expect(m.config.name == "Orchestrator")
        #expect(m.config.crewLimit == 4)
        #expect(m.config.notebook["plan"] == "")
        #expect(m.config.askFirstMinutes == 15)
        #expect(Sync.Document.parse(#"{"format":"something-else","version":1,"settings":{}}"#) == nil)
        #expect(Sync.Document.parse("Scheduled check: look at your threads") == nil)
    }

    @Test func aLocalEditIsStampedAndWritten() throws {
        var c = OrchestratorConfig()
        let old = c
        c.name = "Ada"
        c.notebook["plan"] = "1. Ship"
        let stamps = Sync.stamps(old: old, new: c, into: [:], now: 3000, device: "mac")
        #expect(Set(stamps.keys) == ["name", "notebook.plan"])
        let m = Sync.merge(config: c, stamps: stamps, documents: [], machine: "env-a")
        let doc = try #require(m.write)
        #expect(doc.settings["name"] == .init(value: .string("Ada"), stamp: stamp(3000, "mac")))
        #expect(doc.settings["notebook.plan"]?.value == .string("1. Ship"))
        #expect(doc.settings["crewLimit"] == nil)
        // What it writes reads back the same on the other side.
        let back = try document(doc.prompt)
        #expect(back == doc)
        #expect(Sync.merge(config: OrchestratorConfig(), stamps: [:], documents: [back], machine: "env-a").config.name == "Ada")
    }

    /// Relay bookkeeping and the toggle stay on the device.
    @Test func deviceStateIsNeverStamped() {
        var c = OrchestratorConfig()
        let old = c
        c.enabled = true
        c.relayedAt["env-a:t1"] = 5
        c.machines["env-a"] = OrchestratorMachine(threadId: "t1", briefDigest: "d")
        c.savedMemoryMessages = ["m1"]
        #expect(Sync.stamps(old: old, new: c, into: [:], now: 1, device: "mac").isEmpty)
    }

    /// A nil machine goes up as the machine it means here, since "the primary" differs per device.
    @Test func theMachineGoesUpByName() throws {
        var c = OrchestratorConfig()
        c.environmentId = "env-b"
        let old = c
        c.environmentId = nil
        let stamps = Sync.stamps(old: old, new: c, into: [:], now: 10, device: "mac")
        let doc = try #require(Sync.merge(config: c, stamps: stamps, documents: [], machine: "env-b", home: "env-a").write)
        #expect(doc.settings["environmentId"]?.value == .string("env-a"))
    }

    @Test func migrationUploadsOnlyWhatYouChanged() throws {
        var c = OrchestratorConfig()
        c.enabled = true
        c.name = "Ada"
        c.crewLimit = 2
        c.botColor = 5
        let stamps = Sync.migrationStamps(c, now: 4000, device: "mac")
        #expect(Set(stamps.keys) == ["name", "crewLimit", "botColor"])
        // The phone already set the prompt and the worker limit earlier: your newer values win, its prompt stays.
        let phone = try document("""
        {"format":"candywrapper.orchestrator-settings","version":1,"settings":{
          "prompt":{"value":"Be brief.","at":1000,"by":"phone"},"crewLimit":{"value":8,"at":1000,"by":"phone"}
        }}
        """)
        let m = Sync.merge(config: c, stamps: stamps, documents: [phone], machine: "env-a")
        #expect(m.config.prompt == "Be brief.")
        #expect(m.config.crewLimit == 2)
        #expect(m.config.name == "Ada")
        let doc = try #require(m.write)
        #expect(doc.settings["crewLimit"]?.value == .number(2))
        #expect(doc.settings["prompt"]?.value == .string("Be brief."))
        #expect(doc.settings["botColor"]?.value == .number(5))
        // A device with nothing changed takes everything and writes nothing.
        let fresh = Sync.merge(config: OrchestratorConfig(), stamps: Sync.migrationStamps(OrchestratorConfig(), now: 9, device: "mac2"),
                               documents: [doc], machine: "env-a")
        #expect(fresh.config.name == "Ada")
        #expect(fresh.write == nil)
    }

    /// Two devices edit at once, each before reading the other's write: the later edit wins per setting, other settings
    /// both survive, and both end up the same whichever document they read last.
    @Test func twoDevicesEditingAtOnceAgree() throws {
        let base = Sync.merge(config: OrchestratorConfig(), stamps: [:], documents: [], machine: "env-a")
        var mac = base.config, phone = base.config
        let oldMac = mac, oldPhone = phone
        mac.name = "Mac name"
        mac.crewLimit = 3
        phone.name = "Phone name"
        phone.askFirstMinutes = 30
        let macStamps = Sync.stamps(old: oldMac, new: mac, into: [:], now: 5000, device: "mac")
        let phoneStamps = Sync.stamps(old: oldPhone, new: phone, into: [:], now: 5001, device: "phone")
        // The Mac writes first; the phone, which read the empty document, writes over it.
        let macDoc = try #require(Sync.merge(config: mac, stamps: macStamps, documents: [], machine: "env-a").write)
        let phoneDoc = try #require(Sync.merge(config: phone, stamps: phoneStamps, documents: [], machine: "env-a").write)
        // The Mac reads the phone's document: it takes the newer name, keeps its worker limit and writes that back.
        let macAfter = Sync.merge(config: mac, stamps: macStamps, documents: [phoneDoc], machine: "env-a")
        #expect(macAfter.config.name == "Phone name")
        #expect(macAfter.config.askFirstMinutes == 30)
        #expect(macAfter.config.crewLimit == 3)
        let merged = try #require(macAfter.write)
        // The phone reads that and has nothing to add.
        let phoneAfter = Sync.merge(config: phone, stamps: phoneStamps, documents: [merged], machine: "env-a")
        #expect(phoneAfter.config == macAfter.config)
        #expect(phoneAfter.write == nil)
        // Read the other way round, the result is the same.
        let phoneFirst = Sync.merge(config: phone, stamps: phoneStamps, documents: [macDoc], machine: "env-a")
        #expect(phoneFirst.config == macAfter.config)
        // A tie goes to the larger device id on both sides.
        let a = Sync.Entry(value: .string("A"), stamp: stamp(7, "aaa")), b = Sync.Entry(value: .string("B"), stamp: stamp(7, "bbb"))
        let tie = Sync.merge(config: OrchestratorConfig(), stamps: [:], documents: [.init(settings: ["name": a]), .init(settings: ["name": b])], machine: "env-a")
        #expect(tie.config.name == "B")
    }

    /// Two documents on one machine become one; keys a newer client wrote survive.
    @Test func duplicatesMergeAndUnknownKeysSurvive() throws {
        let one = Sync.Document(settings: ["name": .init(value: .string("Old"), stamp: stamp(1, "mac")),
                                           "futureThing": .init(value: .bool(true), stamp: stamp(1, "phone"))])
        let two = Sync.Document(settings: ["name": .init(value: .string("New"), stamp: stamp(2, "phone"))])
        let m = Sync.merge(config: OrchestratorConfig(), stamps: [:], documents: [one, two], machine: "env-a")
        #expect(m.config.name == "New")
        let doc = try #require(m.write)
        #expect(doc.settings["futureThing"]?.value == .bool(true))
        #expect(doc.settings["name"]?.value == .string("New"))
    }
}
