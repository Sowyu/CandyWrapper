import Foundation

extension RepositoryIdentity {
    /// `pullRequestHostOf` (pullRequest.ts:1311): the canonical key's first segment, or the
    /// web origin's host for Forgejo.
    public var pullRequestHost: String? {
        guard let kind = provider else { return nil }
        if kind == "forgejo", case .object(let o) = locator, let remote = o["remoteUrl"]?.stringValue,
           let url = URL(string: remote), url.scheme == "http" || url.scheme == "https", let host = url.host {
            return url.port.map { "\(host.lowercased()):\($0)" } ?? host.lowercased()
        }
        let host = canonicalKey.split(separator: "/").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return host.isEmpty ? kind : host.lowercased()
    }

    /// `sourceControlRepositorySelector` (shared/sourceControl.ts:287-300): how pull request reads
    /// name the repository.
    public var pullRequestRepository: String? {
        if provider == "azure-devops" {
            let segments = (displayName ?? "").split(separator: "/").map(String.init).filter { $0 != "_git" }
            return name ?? segments.last
        }
        if let displayName { return displayName }
        if let owner, let name { return "\(owner)/\(name)" }
        return nil
    }

    /// Whether a change request link belongs to this repository (`findProjectForChangeRequest`,
    /// without Forgejo web roots).
    public func owns(_ link: ChangeRequestURL.Link) -> Bool {
        guard let host = pullRequestHost, let repository = pullRequestRepository else { return false }
        if provider == "azure-devops" {
            return ChangeRequestURL.canonicalRepositoryKey(canonicalKey.lowercased())
                == ChangeRequestURL.canonicalRepositoryKey("\(link.host)/\(link.repository)".lowercased())
        }
        return host == (link.authority ?? link.host).lowercased() && repository.lowercased() == link.repository.lowercased()
    }
}
