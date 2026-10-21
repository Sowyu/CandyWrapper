import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The commit dialog's buttons used to capture the dialog and its host strongly, so every opened and cancelled
/// dialog stayed in memory. Bound with `bind(to:)` and owned only while presented, dismissal frees all of it.
@MainActor
struct CommitDialogReleaseTests {
    /// Stands in for GitController's `commitDialog`, the explicit owner while the dialog is open.
    final class Owner { var dialog: CommitDialog? }

    @Test func dismissedDialogIsReleased() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = DSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let owner = Owner()
        for _ in 0..<2 {
            weak var weakDialog: CommitDialog?
            weak var weakHost: ModalHost?
            weak var weakPanel: DialogView?
            autoreleasepool {
                let commit = CommitDialog(branch: "main", isDefaultRef: false, files: [VcsStatus.File(path: "a.swift", insertions: 1, deletions: 0)],
                                          canChangeBranch: true, canWrite: true)
                let host = ModalHost.present(commit.dialog, in: window, blurBackdrop: false)
                owner.dialog = commit
                host.onDismiss = { [weak owner] in owner?.dialog = nil }
                commit.bind(to: host) { _, _, _ in }
                weakDialog = commit
                weakHost = host
                weakPanel = commit.dialog
                host.close(animated: false)
            }
            #expect(owner.dialog == nil)
            #expect(weakDialog == nil)
            #expect(weakHost == nil)
            #expect(weakPanel == nil)
        }
    }
}
