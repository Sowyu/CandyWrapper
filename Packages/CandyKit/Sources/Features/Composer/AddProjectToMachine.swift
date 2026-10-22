import Foundation
import T3Protocol

/// "Add to another machine" (T3 #22180 and #22254): the rules behind the Run on entry and its dialog.
/// Clone URL rewriting, ignored file picks and the request payloads come from apps/web/src/lib/addProjectToMachine.ts,
/// the target list from hooks/useAddProjectTargets.ts and the rest from components/AddProjectToMachineDialog.tsx.
public enum AddProjectToMachine {
    /// A machine the project can be cloned onto (`AddProjectTarget`).
    public struct Target: Equatable, Sendable {
        public var environmentId: String
        public var label: String
        public var machine: String
        public init(environmentId: String, label: String, machine: String) {
            self.environmentId = environmentId; self.label = label; self.machine = machine
        }
    }

    /// What `useAddProjectTargets` reads about each connected environment.
    public struct Candidate: Equatable, Sendable {
        public var target: Target
        /// `canCreateProjectInEnvironment`: the connection phase is "connected".
        public var connected: Bool
        /// The session grants `source-control:write`.
        public var canClone: Bool
        /// The server config advertises `projectCloneTracking`.
        public var tracksClones: Bool
        public init(target: Target, connected: Bool, canClone: Bool, tracksClones: Bool) {
            self.target = target; self.connected = connected; self.canClone = canClone; self.tracksClones = tracksClones
        }
    }

    /// `useAddProjectTargets` (useAddProjectTargets.ts:16-41): connected machines that do not have the project
    /// yet and can clone it, by label. A project without a git remote gets none.
    public static func targets(remoteUrl: String?, sourceEnvironmentId: String?, projectEnvironmentIds: [String],
                               candidates: [Candidate]) -> [Target] {
        guard let remoteUrl, !remoteUrl.isEmpty else { return [] }
        let has = Set(projectEnvironmentIds + [sourceEnvironmentId].compactMap { $0 })
        return candidates
            .filter { !has.contains($0.target.environmentId) && $0.canClone && $0.connected && $0.tracksClones }
            .map(\.target)
            .sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
    }

    /// The repository's remote URL from a project's repository identity (`repositoryIdentity.locator.remoteUrl`).
    public static func remoteUrl(_ project: ProjectShell?) -> String? {
        project?.repositoryIdentity?.locator["remoteUrl"]?.stringValue
    }

    // MARK: Clone URLs (addProjectToMachine.ts:20-59)

    public enum CloneProtocol: String, Sendable { case ssh, https }

    private struct ParsedUrl { var proto: CloneProtocol; var host: String; var path: String; var customPort: Bool }

    private static let scpLike = try! NSRegularExpression(pattern: #"^(?:[^@/\s]+@)?([^:/\s]+):(?!/)(.+)$"#)
    private static let sshUrl = try! NSRegularExpression(pattern: #"^ssh://(?:[^@/\s]+@)?([^:/\s]+)(:\d+)?/(.+)$"#)
    private static let httpsUrl = try! NSRegularExpression(pattern: #"^https?://(?:[^@/\s]+@)?([^:/\s]+)(:\d+)?/(.+)$"#)

    private static func groups(_ regex: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
    }

    private static func parse(_ url: String) -> ParsedUrl? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let g = groups(sshUrl, trimmed) { return ParsedUrl(proto: .ssh, host: g[0]!, path: g[2]!, customPort: g[1] != nil) }
        if let g = groups(httpsUrl, trimmed) { return ParsedUrl(proto: .https, host: g[0]!, path: g[2]!, customPort: g[1] != nil) }
        if let g = groups(scpLike, trimmed) { return ParsedUrl(proto: .ssh, host: g[0]!, path: g[1]!, customPort: false) }
        return nil
    }

    /// `cloneUrlProtocol`.
    public static func cloneUrlProtocol(_ url: String) -> CloneProtocol? { parse(url)?.proto }

    /// `cloneUrlForProtocol`: the URL rewritten to the other protocol, since the other machine may only have SSH
    /// keys or only an HTTPS credential helper. Nil when it cannot be rewritten safely, such as a custom port.
    public static func cloneUrl(_ url: String, for proto: CloneProtocol) -> String? {
        guard let parsed = parse(url) else { return nil }
        if parsed.proto == proto { return url.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parsed.customPort { return nil }
        return proto == .ssh ? "git@\(parsed.host):\(parsed.path)" : "https://\(parsed.host)/\(parsed.path)"
    }

    /// The URL the clone uses (AddProjectToMachineDialog.tsx:86-90): the picked protocol's form, else the source's.
    public static func remoteUrl(source: String, protocol proto: CloneProtocol?) -> String {
        proto.flatMap { cloneUrl(source, for: $0) } ?? source
    }

    // MARK: Ignored files

    /// `COPYABLE_FILE_MAX_BYTES`: the server's read cap; a larger file would arrive truncated.
    public static let copyableFileMaxBytes = 1024 * 1024

    /// `ProjectIgnoredFile` (packages/contracts/src/project.ts:314-318).
    public struct IgnoredFile: Equatable, Sendable {
        public var path: String
        public var byteLength: Int
        public init(path: String, byteLength: Int) { self.path = path; self.byteLength = byteLength }
        public var tooLarge: Bool { byteLength > AddProjectToMachine.copyableFileMaxBytes }
    }

    /// `ProjectListIgnoredFilesResult`: the files and whether the server stopped at its limit of 200.
    public static func ignoredFiles(_ json: JSONValue?) -> (files: [IgnoredFile], truncated: Bool) {
        let files = (json?["files"]?.arrayValue ?? []).compactMap { entry -> IgnoredFile? in
            guard let path = entry["path"]?.stringValue, !path.isEmpty, let bytes = entry["byteLength"]?.doubleValue else { return nil }
            return IgnoredFile(path: path, byteLength: Int(bytes))
        }
        return (files, json?["truncated"]?.boolValue ?? false)
    }

    private static let defaultCopiedName = try! NSRegularExpression(pattern: #"^(?:\.env(?:\..+)?|\.envrc|\.dev\.vars)$"#)

    /// `isDefaultCopiedFile`: env files are the ignored files people almost always want on a new machine.
    public static func isDefaultCopiedFile(_ path: String) -> Bool {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        return groups(defaultCopiedName, name) != nil
    }

    /// `defaultSelection` (AddProjectToMachineDialog.tsx:397-405): the env files small enough to copy.
    public static func defaultSelection(_ files: [IgnoredFile]) -> Set<String> {
        Set(files.filter { !$0.tooLarge && isDefaultCopiedFile($0.path) }.map(\.path))
    }

    /// The All and None button (AddProjectToMachineDialog.tsx:319-332): every copyable file, or none once all are picked.
    public static func toggleAll(_ files: [IgnoredFile], selected: Set<String>) -> Set<String> {
        let copyable = files.filter { !$0.tooLarge }
        return selected.count == copyable.count ? [] : Set(copyable.map(\.path))
    }

    /// "N of M · size" beside "Copy ignored files" (AddProjectToMachineDialog.tsx:315-318).
    public static func selectionSummary(_ files: [IgnoredFile], selected: Set<String>) -> String {
        let bytes = files.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.byteLength }
        return "\(selected.count) of \(files.count)" + (bytes > 0 ? " \u{00B7} \(StorageCleanupReport.formatBytes(Double(bytes)))" : "")
    }

    /// The arrow's caption (AddProjectToMachineDialog.tsx:234-238).
    public static func filesCaption(_ count: Int) -> String {
        count == 0 ? "no files" : "+ \(count) \(count == 1 ? "file" : "files")"
    }

    /// `projectSubdirectory` (AddProjectToMachineDialog.tsx:388-395): where a project sits below its repository's top
    /// folder. The clone lands at the top, so copied files keep the same path below it.
    public static func projectSubdirectory(repositoryRoot: String?, workspaceRoot: String) -> String {
        guard let repositoryRoot, !repositoryRoot.isEmpty else { return "" }
        var prefix = repositoryRoot
        while let last = prefix.last, last == "/" || last == "\\" { prefix.removeLast() }
        guard workspaceRoot.hasPrefix(prefix) else { return "" }
        let rest = workspaceRoot.dropFirst(prefix.count)
        guard let first = rest.first, first == "/" || first == "\\" else { return "" }
        return String(rest.dropFirst()).replacingOccurrences(of: "\\", with: "/")
    }

    /// The default folder on the other machine (AddProjectToMachineDialog.tsx:93-96): its add-project base directory
    /// (else `~/`) plus the repository's folder name.
    public static func defaultDestination(baseDirectory: String?, remoteUrl: String) -> String {
        let base = baseDirectory?.trimmingCharacters(in: .whitespaces) ?? ""
        let directory = base.isEmpty ? "~/" : PaletteAddProjectPaths.ensureDirectoryPath(base)
        return PaletteAddProjectPaths.cloneDestinationPath(directory, PaletteAddProjectPaths.cloneDirectoryName(remoteUrl))
    }

    // MARK: Requests

    /// `projects.listIgnoredFiles` (contracts/src/project.ts:309-311).
    public static func listIgnoredFilesPayload(cwd: String) -> JSONValue { .object(["cwd": .string(cwd)]) }

    /// `projects.readFile` for one file to copy (addProjectToMachine.ts:146-152).
    public static func readFilePayload(cwd: String, relativePath: String) -> JSONValue {
        .object(["cwd": .string(cwd), "relativePath": .string(relativePath)])
    }

    /// `projectClone.start` on the other machine (addProjectToMachine.ts:165-179).
    public static func cloneStartPayload(projectId: String, title: String, createdAt: String, remoteUrl: String, destinationPath: String) -> JSONValue {
        .object([
            "projectId": .string(projectId), "title": .string(title), "createdAt": .string(createdAt),
            "remoteUrl": .string(remoteUrl), "destinationPath": .string(destinationPath),
        ])
    }

    /// `projects.writeFile` into the clone (addProjectToMachine.ts:198-212), under the project's subdirectory.
    public static func writeFilePayload(cwd: String, subdirectory: String, relativePath: String, contents: String) -> JSONValue {
        .object([
            "cwd": .string(cwd), "relativePath": .string(subdirectory.isEmpty ? relativePath : "\(subdirectory)/\(relativePath)"),
            "contents": .string(contents),
        ])
    }

    /// The failed copy banner's title (addProjectToMachine.ts:222).
    public static func copyFailureTitle(count: Int, machine: String) -> String {
        "Could not copy \(count) \(count == 1 ? "file" : "files") to \(machine)"
    }
}
