import Foundation
import SQLite3
import T3Protocol

/// Which T3 runtime starts the server for a home, and the check that keeps an older one away from
/// data a newer one already migrated. T3's servers start on a newer database with only a warning
/// (persistence/Migrations.ts:198-221), so the client has to refuse.
public enum RuntimeChoice: Equatable, Sendable {
    case t3(T3Version, URL)
    case ours(T3Version, URL)
    case install(T3Version)

    /// T3's installed runtime when it is newer than ours, else ours, else an install of `wanted` (or
    /// of the floor, when the floor is newer). Neither may be older than `floor`.
    public static func decide(t3: (T3Version, URL)?, ours: (T3Version, URL)?, wanted: T3Version, floor: T3Version?) -> RuntimeChoice {
        func allowed(_ v: T3Version) -> Bool { floor.map { v >= $0 } ?? true }
        if let t3, allowed(t3.0), ours.map({ t3.0 > $0.0 }) ?? true { return .t3(t3.0, t3.1) }
        if let ours, allowed(ours.0) { return .ours(ours.0, ours.1) }
        return .install(floor.map { max($0, wanted) } ?? wanted)
    }
}

/// What CandyWrapper knows about each T3 home it started a server on, in `<runtimes>/homes.json`:
/// the newest version it started there, and the newest migration each version left in the database.
public struct HomeRecords: Sendable {
    public struct Home: Codable, Equatable, Sendable {
        public var highest: String?
        public var migrations: [String: Int] = [:]
        public init(highest: String? = nil, migrations: [String: Int] = [:]) { self.highest = highest; self.migrations = migrations }
    }

    public let file: URL
    public init(file: URL) { self.file = file }
    public static var standard: HomeRecords { HomeRecords(file: RuntimeStore.standard.root.appending(path: "homes.json")) }

    private static func key(_ home: URL) -> String { home.standardizedFileURL.path }

    public func all() -> [String: Home] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Home].self, from: $0) } ?? [:]
    }

    public func home(_ home: URL) -> Home { all()[Self.key(home)] ?? Home() }

    /// After a server started on `home` with `version`: raise the floor, and note the migration it left.
    public func recordStart(_ version: String, home: URL, migration: Int?) {
        var records = all()
        var h = records[Self.key(home)] ?? Home()
        if let v = T3Version(version), h.highest.flatMap(T3Version.init).map({ v > $0 }) ?? true { h.highest = version }
        if let migration { h.migrations[version] = max(h.migrations[version] ?? 0, migration) }
        records[Self.key(home)] = h
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    /// The oldest version allowed on `home`: the newest of what CandyWrapper started there, what T3's
    /// service last ran or is switching to (`<home>/runtime/service-state.json`), and `others` (an
    /// installed T3 Code app, which runs its own server on the same home).
    public func floor(home: URL, others: [String] = []) -> T3Version? {
        var versions = [self.home(home).highest].compactMap { $0 } + others
        if let data = try? Data(contentsOf: home.appending(path: "runtime/service-state.json")),
           let state = try? JSONDecoder().decode(ServiceState.self, from: data) {
            versions += [state.activeVersion, state.update?.targetVersion].compactMap { $0 }
        }
        return versions.compactMap(T3Version.init).max()
    }

    struct ServiceState: Decodable {
        struct Update: Decodable { var targetVersion: String? }
        var activeVersion: String?
        var update: Update?
    }

    /// Why `candidate` must not start on `home`, or nil. `migration` is the database's newest migration.
    public func refusal(candidate: T3Version, home: URL, floor: T3Version?, migration: Int?) -> String? {
        if let floor, candidate < floor {
            return "CandyWrapper won't start T3 Code \(candidate) on \(home.path): T3 Code \(floor) already used this data, and an older server could damage it. Update T3 Code on this Mac, then try again."
        }
        if let migration, let known = self.home(home).migrations[candidate.raw], migration > known {
            return "CandyWrapper won't start T3 Code \(candidate) on \(home.path): a newer T3 Code changed its database, and an older server could damage it. Update T3 Code on this Mac, then try again."
        }
        return nil
    }

    /// The newest migration T3 recorded in the home's database (`effect_sql_migrations`), read only.
    /// Nil when there is no database yet. Call it only while no server runs on the home.
    public static func databaseMigration(home: URL) -> Int? {
        let userdata = home.appending(path: "userdata")
        let candidates = ["statev2.sqlite", "state.sqlite"].map { userdata.appending(path: $0) }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })?.path else { return nil }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(migration_id) FROM effect_sql_migrations", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
