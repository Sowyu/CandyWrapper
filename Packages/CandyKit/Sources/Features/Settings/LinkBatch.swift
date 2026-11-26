import Foundation

/// Linking several machines from one environment at once (T3 5258 client-runtime/src/linkBatch.ts). The client mints
/// each pairing code on its machine with its own session there and hands it straight to the linking environment;
/// a code is never held, shown or logged.
public enum LinkBatch {
    /// Why a batch cannot link a machine (linkBatch.ts:22-27).
    public enum Block: String, Sendable { case linksUnknown = "links_unknown", linked, notConnected = "not_connected", noAccess = "no_access", noAddress = "no_address" }

    /// Whether the linking environment's own links are known yet (linkBatch.ts:30).
    public enum ListState: Sendable { case loading, failed, loaded }

    public struct Candidate: Equatable {
        public var machine: LinkableMachine
        public var blocked: Block?
    }

    /// `linkBatchCandidates` (linkBatch.ts:46-63). Until the links have loaded none is offered: linking one already
    /// linked would replace its working token.
    public static func candidates(_ machines: [LinkableMachine], writable: Set<String>, links: ListState) -> [Candidate] {
        machines.map { machine in
            Candidate(machine: machine, blocked: links != .loaded ? .linksUnknown : machine.linked ? .linked
                      : !machine.connected ? .notConnected : !writable.contains(machine.environmentId) ? .noAccess
                      : machine.urls.isEmpty ? .noAddress : nil)
        }
    }

    public static func blockLabel(_ block: Block) -> String {
        switch block {
        case .linksUnknown: "Not known yet whether it is linked"
        case .linked: "Already linked"
        case .notConnected: "This app is not connected to it"
        case .noAccess: "Your session there cannot create pairing codes"
        case .noAddress: "No address another machine can reach"
        }
    }

    /// `LinkBatchFailure` (linkBatch.ts:178, contracts peerLink.ts:95-104).
    public enum Failure: String, Sendable { case unreachable, codeRefused = "code_refused", wrongEnvironment = "wrong_environment", other, noCode = "no_code" }

    public static func failureLabel(_ failure: Failure) -> String {
        switch failure {
        case .unreachable: "Unreachable"
        case .codeRefused: "Pairing code refused"
        case .wrongEnvironment: "Another environment answered"
        case .noCode: "Could not get a pairing code there"
        case .other: "Could not link"
        }
    }

    /// `peerLinkFailureKind`: a `PeerLinkError`'s reason, or another machine answering.
    public static func failure(reason: String?, answeredAs: Bool) -> Failure {
        if answeredAs { return .wrongEnvironment }
        switch reason {
        case "unreachable", "not_a_t3_environment": return .unreachable
        case "pairing_rejected": return .codeRefused
        default: return .other
        }
    }

    public enum Attempt: Equatable, Sendable {
        case linked
        case failed(Failure, detail: String?)
    }

    /// `back` is set when the link back was asked for; it never changes how the link itself went.
    public enum Outcome: Equatable, Sendable {
        case linked(back: Attempt?)
        case failed(Failure, detail: String?)
        var isLinked: Bool { if case .linked = self { true } else { false } }
    }

    /// The row's status (LinkSeveralEnvironments.tsx:303-322).
    public static func status(linking: Bool, outcome: Outcome?, blocked: Block?) -> String? {
        if linking { return "Linking…" }
        switch outcome {
        case .linked(.linked?)?: return "Linked both ways"
        case .linked(.failed?)?: return "Linked one way"
        case .linked(nil)?: return "Linked"
        case .failed(let failure, _)?: return failureLabel(failure)
        case nil: return blocked.map(blockLabel)
        }
    }

    /// The line under the list once a run ends (:368-387).
    public static func summary(_ outcomes: [String: Outcome]) -> String? {
        guard !outcomes.isEmpty else { return nil }
        let failed = outcomes.values.filter { !$0.isLinked }.count
        let linked = outcomes.count - failed
        var text = failed == 0 ? (linked == 1 ? "Linked 1 machine." : "Linked \(linked) machines.")
            : "Linked \(linked) of \(outcomes.count). The ones that failed stay selected, so you can try them again."
        let backFailed = outcomes.values.filter { if case .linked(.failed?) = $0 { true } else { false } }.count
        if backFailed > 0 { text += backFailed == 1 ? " 1 machine could not link back." : " \(backFailed) machines could not link back." }
        return text
    }

    /// Pairings run at once, so a fleet is not signed in to all at the same moment (linkBatch.ts:16).
    public static let concurrency = 4

    /// `runLinkBatch` (linkBatch.ts:268-318): each machine on its own, four at a time. `link` mints and links one
    /// machine; `back` links it back to the source when asked. A failure stops only its own machine.
    @MainActor
    public static func run(_ machines: [LinkableMachine], link: @escaping @MainActor (LinkableMachine) async -> Attempt,
                           back: (@MainActor (LinkableMachine) async -> Attempt?)? = nil,
                           onOutcome: @escaping @MainActor (String, Outcome) -> Void) async -> [String: Outcome] {
        var queue = machines
        var outcomes: [String: Outcome] = [:]
        func worker() async {
            while !queue.isEmpty {
                let machine = queue.removeFirst()
                let outcome: Outcome
                switch await link(machine) {
                case .linked: outcome = .linked(back: await back?(machine))
                case .failed(let failure, let detail): outcome = .failed(failure, detail: detail)
                }
                outcomes[machine.environmentId] = outcome
                onOutcome(machine.environmentId, outcome)
            }
        }
        let workers = (0..<min(concurrency, machines.count)).map { _ in Task { @MainActor in await worker() } }
        for task in workers { await task.value }
        return outcomes
    }
}
