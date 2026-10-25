import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// "Share with guest" (fb76594d7b at 3669): whether a thread's environment offers it (guestShareAvailability.ts) and the
/// dialog that makes the link (GuestShareControls.tsx:62-185), from the thread menu and the command palette.
@MainActor
final class GuestShareController {
    private let environments: Environments
    private weak var threads: ThreadController?
    private var host: ModalHost?
    /// The open dialog's controller; the host keeps only its view.
    private var sheet: GuestShareDialog?

    init(environments: Environments, threads: ThreadController) {
        self.environments = environments
        self.threads = threads
    }

    /// `canShareWithGuestAtom`: the user may call `guestShare.create` there and its Guest links beta is on. A server
    /// without the setting (before 3669) never offers it.
    func canShare(_ environmentId: String?) -> Bool {
        guard let environmentId else { return false }
        return environments.canCreateGuestShare(environmentId)
            && threads?.composer.config(environmentId)?.settings.raw["guestSharingEnabled"] == .bool(true)
    }

    /// `openGuestShareDialog` for a scoped thread id.
    // ponytail: "A new link ends the current one." knows only the open thread's share, where T3 reads any thread's
    // projection; read the thread's projection here if sharing from the sidebar for another thread needs it
    func present(_ threadId: ThreadId, in window: NSWindow) {
        guard host == nil, let env = threadId.environmentId else { return }
        let active = threads?.lineage.guest.share(for: threadId) != nil
        let sheet = GuestShareDialog(hasActiveShare: active, canCreate: environments.canCreateGuestShare(env))
        let host = ModalHost.present(sheet.dialog, in: window)
        self.host = host
        self.sheet = sheet
        host.onDismiss = { [weak self, weak host] in if self?.host === host { self?.host = nil; self?.sheet = nil } }
        sheet.onClose = { [weak host] in host?.close() }
        sheet.onCopy = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
        sheet.onCreate = { [weak self, weak host, weak sheet] in
            host?.allowsUserDismissal = false
            Task { [weak self] in
                let outcome = await self?.create(threadId, environmentId: env)
                host?.allowsUserDismissal = true
                switch outcome {
                case .created(let url)?: sheet?.succeeded(url: url)
                case .failed(let message)?: sheet?.failed(message)
                case .interrupted?, nil: sheet?.reset()
                }
            }
        }
    }

    enum Outcome { case created(String), failed(String), interrupted }

    /// `guestShare.create` (rpc.ts:1850-1854). A `GuestShareCreateError` shows T3's text for its `reason`; another
    /// failure shows its own message, else "Could not create a guest link."
    private func create(_ threadId: ThreadId, environmentId: String) async -> Outcome {
        do {
            let reply = try await environments.request(environmentId, "guestShare.create", ThreadCommands.createGuestShare(threadId.localId))
            guard let url = reply["url"]?.stringValue else { return .failed(GuestShareCreateError.fallback) }
            return .created(url)
        } catch let error as RPCClientError {
            // An interrupted call goes back to the start (`isAtomCommandInterrupted`).
            if case .failure(let causes) = error, !causes.isEmpty, causes.allSatisfy({ if case .interrupt = $0 { true } else { false } }) {
                return .interrupted
            }
            let typed = error.typedError
            if typed?.tag == "GuestShareCreateError", let text = GuestShareCreateError.message(reason: typed?.fields["reason"]?.stringValue) {
                return .failed(text)
            }
            return .failed(typed?.message ?? GuestShareCreateError.fallback)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? GuestShareCreateError.fallback)
        }
    }
}
