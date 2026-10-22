import Foundation
import Testing

/// Tests that start a real `t3 serve`, talk to the sandbox server or write the login Keychain. They run
/// only under `scripts/test-integration`, which sets `CW_INTEGRATION=1`; the default suite reports
/// them as skipped instead of passing them without doing anything.
let integrationEnabled = ProcessInfo.processInfo.environment["CW_INTEGRATION"] == "1"

extension Trait where Self == ConditionTrait {
    static var integration: Self {
        .enabled(if: integrationEnabled, "needs a real T3 server, the sandbox or the Keychain: run scripts/test-integration")
    }
}
