import T3Protocol

public enum ThreadLinkResolution {
    /// Prefer written then decoded ids in the named environment. Only v1 permits a unique
    /// match elsewhere (packages/shared/src/threadLinks.ts:45-73, 3814).
    public static func resolve(_ link: ThreadLink, messageEnvironmentId: String, threads: [ThreadShell]) -> ThreadShell? {
        let environment = link.environmentId ?? messageEnvironmentId
        let ids = [link.threadId, link.percentDecoded?.threadId].compactMap { $0 }
        for id in ids {
            if let local = threads.first(where: { $0.id == ThreadId(id).scoped(to: environment) }) { return local }
        }
        guard link.environmentId == nil else { return nil }
        for id in ids {
            let matches = threads.filter { $0.id.localId.rawValue == id }
            if matches.count > 1 { return nil }
            if let match = matches.first { return match }
        }
        return nil
    }
}
