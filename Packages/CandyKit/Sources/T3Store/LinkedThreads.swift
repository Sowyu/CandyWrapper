import Foundation
import T3Protocol

/// Reading a linked environment's thread through the environment this app is connected to (5258
/// packages/client-runtime/src/linkedThread.ts, T3 commits 1cb3a8c753 #39406 and d7f6b3efca #39439).
public enum LinkedThreads {
    public enum Open: Equatable, Sendable { case direct, linked, unavailable }

    /// `resolveLinkedThreadOpen` (linkedThread.ts:50-62): a connection of the app's own always wins; without one
    /// the environment holding the link reads it; a saved environment (`ownConnected` not nil) that is neither still opens directly.
    public static func resolveOpen(environmentId: String, viaEnvironmentId: String, ownConnected: Bool?, linked: Bool) -> Open {
        if environmentId == viaEnvironmentId { return .direct }
        if ownConnected == true { return .direct }
        if linked { return .linked }
        return ownConnected == nil ? .unavailable : .direct
    }

    /// `LINKED_THREAD_RETRY_MS` (linkedThread.ts:232): the wait before asking again for a thread whose environment
    /// did not answer.
    public static let retrySeconds: Double = 15

    public struct Failure: Equatable, Sendable {
        public var title: String
        public var detail: String
        /// Reading again can succeed with nothing changed: only `unreachable`.
        public var retryable: Bool
    }

    /// Whether a failed read can succeed later: the linked environment was only out of reach (linkedThread.ts:118-123).
    public static func isUnreachable(_ error: RPCTypedError?) -> Bool {
        error?.tag == PeerLinkRPC.threadReadErrorTag && error?.fields["reason"]?.stringValue == "unreachable"
    }

    /// `linkedThreadFailure` (linkedThread.ts:135-216): a failed read in the user's words. `message` is the
    /// server's text for an error that is not a `PeerLinkThreadReadError`.
    public static func failure(_ error: RPCTypedError?, message: String, via: String, label fallback: String) -> Failure {
        let serverMessage = error?.message ?? ""
        guard let error, error.tag == PeerLinkRPC.threadReadErrorTag else {
            // An environment from before this read answers with an unknown method.
            return Failure(title: "Could not read this thread through \(via)",
                           detail: serverMessage.isEmpty ? (message.isEmpty ? "\(via) may need an update before it can read linked threads." : message) : serverMessage,
                           retryable: true)
        }
        let retryable = isUnreachable(error)
        let label = error.fields["label"]?.stringValue ?? fallback
        switch error.fields["reason"]?.stringValue ?? "" {
        case "disabled":
            return Failure(title: "Linked environments is off on \(via)",
                           detail: "Turn it on in \(via)'s Settings → Labs to read threads on the machines it links to.", retryable: retryable)
        case "unknown_link":
            return Failure(title: "\(via) is no longer linked to \(label)",
                           detail: "Link it again in \(via)'s Settings → Connections to read its threads from here.", retryable: retryable)
        case "expired":
            return Failure(title: "The link from \(via) to \(label) expired",
                           detail: "Link it again in \(via)'s Settings → Connections with a new pairing code.", retryable: retryable)
        case "rejected":
            return Failure(title: "\(label) refused the read", detail: serverMessage, retryable: retryable)
        case "thread_not_found":
            return Failure(title: "This thread is no longer on \(label)", detail: "It may have been deleted there.", retryable: retryable)
        case "incompatible":
            return Failure(title: "\(label) needs an update", detail: serverMessage, retryable: retryable)
        default:
            return Failure(title: "\(label) is not answering \(via)", detail: serverMessage, retryable: retryable)
        }
    }

    /// `isLinkedThreadWorking` (linkedThread.ts:222-228): work under way, for the bar's "· Working".
    public static func isWorking(_ projection: ThreadProjection) -> Bool {
        TimelineRunState(projection: projection).isWorking
    }

    /// The bar's status line (LinkedThreadPane.tsx:56-60).
    public static func status(label: String, via: String, working: Bool) -> String {
        working ? "On \(label) via \(via) · Working" : "On \(label) via \(via)"
    }

    /// The server offers the linked reads (wire A6 gate, environment.ts:195): `linkThreadStream`.
    public static func offered(_ capabilities: Set<String>) -> Bool {
        capabilities.contains(PeerLinkRPC.threadStreamCapability)
    }
}

/// Where a side thread opens (5258 packages/client-runtime/src/sideThread.ts:59-88): the `sideThreadOpenTarget`
/// preference for a plain click, the other place for a Cmd-click or a middle click, and the main screen whenever
/// there is no panel to open it in.
public enum SideThreadOpen: String, Sendable, Equatable {
    case panel, main

    public enum Intent: Sendable, Equatable { case primary, alternate }

    public static func resolve(preference: String, intent: Intent, panelAvailable: Bool) -> SideThreadOpen {
        guard panelAvailable else { return .main }
        let preferred = SideThreadOpen(rawValue: preference) ?? .panel
        switch intent {
        case .primary: return preferred
        case .alternate: return preferred == .panel ? .main : .panel
        }
    }

    /// `sideThreadOpenIntentOf` on macOS: the middle button or Cmd is the alternate intent.
    public static func intent(command: Bool, middleButton: Bool) -> Intent { middleButton || command ? .alternate : .primary }
}

/// "Connect to interact" (5258 client-runtime linkedThread.ts:64-110, web state/linkedThreadView.ts:186-275, T3
/// commit d7f6b3efca #39439): pair this device with the linked environment through the one it reads by.
public enum LinkedThreadConnect {
    /// `LinkedEnvironmentConnection`.
    public enum Outcome: Equatable, Sendable {
        case connected
        case unreachable(label: String)
        /// Pair by hand: the address to prefill, when one answered or was offered.
        case manual(label: String, host: String?)
    }

    /// `linkedEnvironmentConnectAtom`'s phases.
    public enum Phase: Equatable, Sendable {
        case idle, connecting
        case unreachable(label: String)
        case manual(label: String, host: String?)
    }

    /// `connectLinkedEnvironment`: asks for a pairing (nil when the linking environment could not answer or may not
    /// be asked), probes every offered address at once and takes the first that answers in the offered order, then
    /// pairs there with the one-time credential.
    public static func connect(label: String,
                               requestPairing: @Sendable () async -> PeerLinkClientPairingResult?,
                               reaches: @escaping @Sendable (String) async -> Bool,
                               pair: @Sendable (_ host: String, _ code: String) async -> Bool) async -> Outcome {
        guard let pairing = await requestPairing() else { return .manual(label: label, host: nil) }
        let probes = pairing.urls.map { url in Task { await reaches(url) ? url : nil } }
        var host: String?
        for probe in probes {
            host = await probe.value
            if host != nil { break }
        }
        for probe in probes { probe.cancel() }
        if pairing.type == "unsupported" { return .manual(label: pairing.label, host: host ?? pairing.urls.first) }
        guard let host else { return .unreachable(label: pairing.label) }
        guard let code = pairing.credential else { return .manual(label: pairing.label, host: host) }
        return await pair(host, code) ? .connected : .manual(label: pairing.label, host: host)
    }

    public static func phase(after outcome: Outcome) -> Phase {
        switch outcome {
        case .connected: .idle
        case .unreachable(let label): .unreachable(label: label)
        case .manual(let label, let host): .manual(label: label, host: host)
        }
    }

    /// The notice above the bar (LinkedThreadPane.tsx:109-145): nil while idle.
    public struct Notice: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case connecting, unreachable, manual }
        public var kind: Kind
        public var title: String
        public var detail: String?
        /// "Enter code", only to pair by hand.
        public var action: String?
    }

    public static func notice(_ phase: Phase, label: String) -> Notice? {
        switch phase {
        case .idle: nil
        case .connecting: Notice(kind: .connecting, title: "Connecting to \(label)…")
        case .unreachable(let named):
            Notice(kind: .unreachable, title: "\(named) is not reachable from this device",
                   detail: "Join a network it is on, such as its Tailscale network, and try again. You can keep reading here.")
        case .manual(let named, _):
            Notice(kind: .manual, title: "\(named) needs a pairing code",
                   detail: "Create one on it, then add it to this device as an environment.", action: "Enter code")
        }
    }
}
