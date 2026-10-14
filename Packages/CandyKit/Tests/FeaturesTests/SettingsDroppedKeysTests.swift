import Foundation
import Testing
import T3Protocol
@testable import Features

/// `droppedSettingKeys` against scopedSettings.test.ts in the 3105 tree (8ac4b97da).
struct SettingsDroppedKeysTests {
    static func json(_ text: String) -> JSONValue { try! JSONValue(parsing: Data(text.utf8)) }

    @Test func reportsKeysTheServerKept() {
        let previous = Self.json(#"{"a":1,"b":"x","nested":{"on":false,"level":2},"gone":"v"}"#)
        // An unknown top-level key and a nested one an older server dropped; the sibling saved.
        let patch = Self.json(#"{"a":2,"newKey":true,"nested":{"on":true,"level":3}}"#).objectValue!
        let saved = Self.json(#"{"a":2,"b":"x","nested":{"on":false,"level":3},"gone":"v"}"#)
        #expect(SettingsScopeState.droppedKeys(patch, previous: previous, saved: saved) == ["nested", "newKey"])
        // Unchanged values, trimmed strings and cleared fields that saved are fine.
        let fine = Self.json(#"{"a":1,"b":" x ","gone":null}"#).objectValue!
        #expect(SettingsScopeState.droppedKeys(fine, previous: previous, saved: Self.json(#"{"a":1,"b":"x"}"#)).isEmpty)
        #expect(SettingsScopeState.droppedKeys(["gone": .null], previous: previous, saved: previous) == ["gone"])
    }
}
