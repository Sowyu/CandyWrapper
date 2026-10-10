import AppKit
import Testing
@testable import Features

@MainActor
struct CopySecretTests {
    /// A copied pairing code carries the markers clipboard managers skip.
    @Test func pairingCredentialIsConcealedAndTransient() {
        let board = NSPasteboard(name: .init("dev.candywrapper.test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        ConnectionsActions.copySecret("ABCD-1234", to: board)
        #expect(board.string(forType: .string) == "ABCD-1234")
        let types = Set(board.types ?? [])
        #expect(types.contains(.init("org.nspasteboard.ConcealedType")))
        #expect(types.contains(.init("org.nspasteboard.TransientType")))
    }
}
