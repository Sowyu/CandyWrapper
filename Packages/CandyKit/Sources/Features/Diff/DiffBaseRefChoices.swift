import Foundation
import T3Protocol

/// One entry of the Changes scope's comparison target picker (lib/baseRefChoices.ts): a local branch paired
/// with its remote, origin first, then the remote-only refs.
public struct DiffBaseRefChoice: Equatable, Sendable {
    public var id: String
    public var label: String
    public var local: VcsRef?
    public var remote: VcsRef?

    /// `buildBaseRefChoices`.
    public static func build(local: [VcsRef], remote: [VcsRef]) -> [DiffBaseRefChoice] {
        func branchName(_ ref: VcsRef) -> String {
            if let remoteName = ref.remoteName, ref.name.hasPrefix(remoteName + "/") { return String(ref.name.dropFirst(remoteName.count + 1)) }
            return ref.name
        }
        var unused = remote
        var choices = local.map { l -> DiffBaseRefChoice in
            let matches = unused.filter { branchName($0) == l.name }
            let pick = matches.first { $0.remoteName == "origin" } ?? matches.first
            if let pick, let i = unused.firstIndex(of: pick) { unused.remove(at: i) }
            return DiffBaseRefChoice(id: "local:\(l.name)", label: l.name, local: l, remote: pick)
        }
        choices += unused.map { DiffBaseRefChoice(id: "remote:\($0.name)", label: $0.name, local: nil, remote: $0) }
        return choices
    }

    /// `valueForBaseRefChoice`: the remote name when that is the picked ref, else the local one.
    public func value(selected: String?) -> String {
        if let selected, selected == remote?.name { return selected }
        return local?.name ?? remote?.name ?? id
    }
}
