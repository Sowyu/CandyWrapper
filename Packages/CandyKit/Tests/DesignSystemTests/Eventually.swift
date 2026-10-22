import Foundation

/// Polls until `condition` holds or `seconds` pass, and returns whether it held. Use it only for
/// things that will happen: the long cap keeps a busy machine (load 100) from failing the test,
/// and a passing run returns as soon as the condition holds. Never use it to show that something
/// did not happen.
@MainActor func eventually(seconds: Int = 30, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<(seconds * 200) {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
