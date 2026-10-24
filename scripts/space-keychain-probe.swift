import Foundation
import Security

// The signed probe scripts/space-keychain-test builds with SpaceCrypto's sources. It stores a synthetic key,
// never a real Space key, and prints only outcomes.
let mode = CommandLine.arguments[1]
let store = SpaceKeyStore(service: CommandLine.arguments[2])
let spaceId = "0f8fad5b-d9cb-469f-a165-70867728950e"
let synthetic = try! SpaceKey(rawBytes: Data(0..<32))
// A denied reader must fail, not open a prompt nobody answers.
SecKeychainSetUserInteractionAllowed(false)
do {
    switch mode {
    case "save": try store.save(synthetic, spaceId: spaceId); print("saved")
    case "read":
        switch try store.load(spaceId: spaceId) {
        case nil: print("missing")
        case let key?: print(key == synthetic ? "match" : "mismatch")
        }
    case "replace": try store.save(.generate(), spaceId: spaceId); print("replaced")
    case "delete": try store.delete(spaceId: spaceId); print("deleted")
    default: print("unknown mode")
    }
} catch {
    print("\(error)")
}
