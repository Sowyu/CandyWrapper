import Foundation
import T3Protocol
import T3Store

/// The Welcome page's state for one computer (WelcomePage.tsx:129-330, `useProjectImport` 1476-1747): its
/// agents, its project scan, the import and the stored project choices. The App supplies the server calls.
@MainActor
public final class WelcomePageModel {
    public let environmentId: String
    public var label: String { didSet { changed() } }
    public var providers: [ServerProvider]? { didSet { changed() } }
    /// The server settings (`serverConfig.settings`), nil until the config arrives.
    public var settings: JSONValue? { didSet { changed() } }
    public var platform = "darwin"
    public var cwd: String?
    public var isPrimary = true { didSet { changed() } }
    /// A T3 Connect build, signed in or not, with relay read and write access on this computer.
    public var offersPhone = false { didSet { changed() } }
    public var canOperateTerminal = true { didSet { changed() } }
    public var canManageProviders = true { didSet { changed() } }
    /// `orchestration:operate`; nil until the session is read.
    public var canWrite: Bool? { didSet { changed() } }
    /// The computer's project roots, which decide whether a candidate is new.
    public var projectRoots: [String] = [] { didSet { changed() } }

    public struct Scan: Equatable {
        public var pending = true
        public var error: String?
        public var truncated = false
        public var candidates: [OnboardingProjectCandidate]?
    }
    public internal(set) var scan = Scan()
    public private(set) var selection: WelcomePageLogic.Selection?
    public private(set) var importing = false

    /// `server.refreshProviders`, for one instance or all.
    public var refreshProviders: ((String?) -> Void)?
    /// The project id a path already has on the computer, from the live list.
    public var existingProjectId: ((String) -> String?)?
    /// Saves the settings and lands. Returns false when the settings could not be saved.
    public var finish: ((_ landing: (env: String, projectId: String)?, _ warning: String, _ importedThreads: Int) async -> Bool)?
    public var request: ((String, JSONValue) async throws -> JSONValue)?
    /// Opens a Settings page over the Welcome page; the page comes back when Settings closes.
    public var openSettings: ((SettingsSection) -> Void)?
    public var signInToConnect: (() -> Void)?
    public var connectSignedOut = true { didSet { changed() } }
    /// `useCloudLinkState` for this computer; nil in a build without T3 Connect.
    public var cloudLinkState: (() async throws -> CloudLinkState)?
    public var now: () -> Int64 = { TimestampFormat.nowMs() }
    private let defaults: UserDefaults

    private var observers: [() -> Void] = []
    public func observe(_ body: @escaping () -> Void) { observers.append(body) }
    private func changed() { observers.forEach { $0() } }

    public init(environmentId: String, label: String, defaults: UserDefaults = .standard) {
        self.environmentId = environmentId; self.label = label; self.defaults = defaults
        if let data = defaults.data(forKey: WelcomePageLogic.selectionKey(environmentId)) {
            selection = try? JSONDecoder().decode(WelcomePageLogic.Selection.self, from: data)
        }
    }

    // MARK: Agents

    public var groups: WelcomePageLogic.Groups { WelcomePageLogic.group(providers, settings: settings) }
    public var agentReady: Bool { groups.readyCount > 0 }

    // MARK: Projects

    public var candidates: [OnboardingProjectCandidate] { scan.candidates ?? [] }
    public func isNew(_ candidate: OnboardingProjectCandidate) -> Bool { WelcomePageLogic.isNew(candidate, roots: projectRoots) }
    public var recent: [OnboardingProjectCandidate] { OnboardingProjectImport.recent(candidates, nowMs: now()).filter(isNew) }
    public var selected: [OnboardingProjectCandidate] {
        WelcomePageLogic.selected(candidates, selection: selection, recent: Set(recent.map(\.key)))
    }
    public var selectedKeys: Set<String> { Set(selected.map(\.key)) }
    public var defaultKeys: [String] { WelcomePageLogic.defaultKeys(candidates, recent: recent, isNew: isNew) }
    public var writable: Bool { canWrite != false }
    public var importError: String? { writable ? nil : OnboardingProjectImport.permissionMessage }

    public func setSelectedKeys(_ keys: Set<String>, optedOut: Bool = false) {
        storeSelection(.init(knownKeys: candidates.map(\.key), keys: candidates.map(\.key).filter(keys.contains), optedOut: optedOut))
    }
    private func storeSelection(_ next: WelcomePageLogic.Selection?) {
        selection = next
        let key = WelcomePageLogic.selectionKey(environmentId)
        if let next, let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
        changed()
    }

    private var scanTask: Task<Void, Never>?
    /// `agentSessions.scan`; Retry and an agent turned on run it again.
    public func refreshScan() {
        scanTask?.cancel()
        scan.pending = true
        scan.error = nil
        changed()
        scanTask = Task { [weak self] in
            guard let self, let request else { return }
            do {
                let result = try await request("agentSessions.scan", .object([:]))
                try Task.checkCancellation()
                scan.candidates = (result["candidates"]?.arrayValue ?? []).compactMap { OnboardingProjectCandidate(environmentId: environmentId, json: $0) }
                scan.truncated = result["truncated"]?.boolValue == true
            } catch is CancellationError {
                return
            } catch {
                scan.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            scan.pending = false
            scanTask = nil
            changed()
        }
    }

    // MARK: Import (WelcomePage.tsx:1596-1730)

    private var importedThreads: [String: Int] = [:]
    private var importedProjects: [String: (env: String, projectId: String)] = [:]
    private var projectsWithHistory: [String: (env: String, projectId: String)] = [:]
    private var projectAttempts: [String: (projectId: String, commandId: String)] = [:]
    private var lastSelection: [String] = []
    private var warning = ""
    private var finishing = false
    private var keepChoices = false

    /// Start: imports the picks, or finishes without them.
    public func start() {
        guard !importing else { return }
        keepChoices = scan.candidates == nil
        let picks = writable ? selected : []
        if picks.isEmpty { finishAfterImport(); return }
        storeSelection(.init(knownKeys: candidates.map(\.key), keys: picks.map(\.key), optedOut: false))
        runImport(picks)
    }

    private var importedThreadTotal: Int { lastSelection.reduce(0) { $0 + (importedThreads[$1] ?? 0) } }

    private func runImport(_ selection: [OnboardingProjectCandidate]) {
        guard let request, writable else { return }
        importing = true
        warning = ""
        lastSelection = selection.map(\.key)
        changed()
        Task { [weak self] in
            guard let self else { return }
            var landed = selection.filter { self.importedProjects[$0.key] != nil }.count
            var skipped = 0
            var refresh = false
            for candidate in selection {
                guard writable else { importing = false; changed(); return }
                let key = candidate.key
                if importedProjects[key] != nil { continue }
                var projectId = candidate.projectId ?? existingProjectId?(candidate.path)
                if projectId == nil {
                    let attempt = projectAttempts[key] ?? {
                        let id = UUID().uuidString.lowercased()
                        return (id, "onboarding:project:create:\(id)")
                    }()
                    projectAttempts[key] = attempt
                    do {
                        _ = try await request("projects.mutate", ProjectCommands.create(
                            projectId: ProjectId(attempt.projectId), workspaceRoot: candidate.path, createWorkspaceRootIfMissing: false,
                            title: candidate.title, commandId: attempt.commandId))
                        projectId = attempt.projectId
                    } catch is CancellationError {
                        importing = false; changed(); return
                    } catch {
                        projectAttempts[key] = nil; refresh = true
                        continue
                    }
                }
                guard let projectId else { continue }
                do {
                    let result = try await request("agentSessions.import", .object([
                        "projectId": .string(projectId), "expectedWorkspaceRoot": .string(candidate.path)]))
                    let count = result["importedCount"]?.intValue ?? 0, missed = result["skippedCount"]?.intValue ?? 0
                    importedThreads[key, default: 0] += count
                    skipped += missed
                    if count > 0 { projectsWithHistory[key] = (environmentId, projectId) }
                    if missed == 0 { landed += 1; importedProjects[key] = (environmentId, projectId) }
                } catch is CancellationError {
                    importing = false; changed(); return
                } catch {
                    projectAttempts[key] = nil; refresh = true
                }
            }
            if refresh { refreshScan() }
            importing = false
            if landed < selection.count { warning = OnboardingProjectImport.warning(imported: importedThreadTotal, skipped: skipped) }
            finishAfterImport()
        }
    }

    /// `finishAfterImport`: busy until setup is saved, so Start cannot run the import again meanwhile.
    public func finishAfterImport() {
        guard !finishing, let finish else { return }
        let landing = OnboardingProjectImport.landing(lastSelection, withHistory: projectsWithHistory, completed: importedProjects)
        finishing = true
        importing = true
        changed()
        Task { [weak self] in
            guard let self else { return }
            let done = await finish(landing, warning, importedThreadTotal)
            finishing = false
            if done {
                if !keepChoices { storeSelection(nil) }
            } else {
                importing = false
                changed()
            }
        }
    }
}
