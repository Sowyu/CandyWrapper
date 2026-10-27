import AppKit
import Foundation
import Testing
import T3Protocol
@testable import Features

/// The share dialog stays live as T3's does (GuestShareControls.tsx:72-75 at 3669): the thread's own projection
/// decides "A new link ends the current one.", and the permission enables Create link while it shows.
@MainActor
struct GuestShareDialogTests {
    static let share = #"{"id":"s","host":"h","createdAt":"2026-10-25T10:00:00.000Z","expiresAt":"2026-10-26T10:00:00.000Z","guestName":null,"messages":[]}"#

    private func projection(shared: Bool) throws -> ThreadProjection {
        let thread = shared ? #"{"id":"other","guestShare":\#(Self.share)}"# : #"{"id":"other"}"#
        return try JSONDecoder().decode(ThreadProjection.self, from: Data(#"{"thread":\#(thread),"runs":[],"updatedAt":"2026-10-25T10:00:00Z"}"#.utf8))
    }

    /// Sharing a thread that isn't open, from the sidebar: no share is known at first, then its own subscription
    /// brings the share and the warning shows, and a closed share takes it away.
    @Test func sidebarShareOfAnotherThreadWarnsFromItsProjection() throws {
        let sheet = GuestShareDialog(hasActiveShare: false, canCreate: true)
        var push: (@MainActor @Sendable (ThreadProjection) -> Void)?
        var watched: [ThreadId] = []
        var stopped = false
        let stop = sheet.follow(ThreadId("env:other")) { id, onProjection in
            watched.append(id)
            push = onProjection
            return { stopped = true }
        }
        #expect(watched == [ThreadId("env:other")])
        #expect(sheet.body.text == "The link works once and expires in 24 hours.")
        push?(try projection(shared: true))
        #expect(sheet.body.text == "A new link ends the current one.")
        push?(try projection(shared: false))
        #expect(sheet.body.text == "The link works once and expires in 24 hours.")
        stop()
        #expect(stopped)
    }

    @Test func permissionChangesWhileOpenUpdateCreateLink() {
        let sheet = GuestShareDialog(hasActiveShare: false, canCreate: false)
        var created = 0
        sheet.onCreate = { created += 1 }
        #expect(!sheet.create.isEnabled)
        sheet.create.action?()
        #expect(created == 0)
        sheet.canCreate = true
        #expect(sheet.create.isEnabled)
        sheet.canCreate = false
        #expect(!sheet.create.isEnabled)
        sheet.canCreate = true
        sheet.create.action?()
        #expect(created == 1)
    }
}
