import Foundation

/// packages/ssh/src/config.ts:14-201. Discovers names without making a connection or running ssh.
public enum SshEnvironmentDiscovery {
    public static func aliases(config: String) -> [String] {
        var result = Set<String>()
        for line in config.components(separatedBy: .newlines) {
            let words = directive(line)
            guard words.first?.lowercased() == "host" else { continue }
            words.dropFirst().filter(concrete).forEach { result.insert($0) }
        }
        return result.sorted { $0.localizedCompare($1) == .orderedAscending }
    }
    public static func knownHosts(_ text: String) -> [String] {
        var result = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            var words = line.split(whereSeparator: \.isWhitespace)
            if words.first?.hasPrefix("@") == true { words.removeFirst() }
            guard let field = words.first, !field.hasPrefix("#"), !field.hasPrefix("|") else { continue }
            for entry in field.split(separator: ",") {
                var host = String(entry)
                if host.hasPrefix("["), let end = host.firstIndex(of: "]") { host = String(host[host.index(after: host.startIndex)..<end]) }
                else if host.filter({ $0 == ":" }).count == 1 { host = String(host.split(separator: ":")[0]) }
                if concrete(host) { result.insert(host) }
            }
        }
        return result.sorted { $0.localizedCompare($1) == .orderedAscending }
    }
    private static func concrete(_ name: String) -> Bool { !name.isEmpty && !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") && !name.hasPrefix("-") }
    private static func directive(_ line: String) -> [String] { String(line.split(separator: "#", omittingEmptySubsequences: false)[0]).replacingOccurrences(of: "=", with: " ").split(whereSeparator: \.isWhitespace).map(String.init) }
    public static func discover(home: URL) throws -> [String] {
        let directory = home.appendingPathComponent(".ssh"), fm = FileManager.default
        var visited = Set<String>(), found = Set<String>()
        func read(_ file: URL) throws {
            let path = file.standardizedFileURL.path
            guard !visited.contains(path), fm.fileExists(atPath: path) else { return }
            visited.insert(path)
            let contents = try String(contentsOf: file, encoding: .utf8)
            aliases(config: contents).forEach { found.insert($0) }
            for line in contents.components(separatedBy: .newlines) {
                let words = directive(line)
                guard words.first?.lowercased() == "include" else { continue }
                for raw in words.dropFirst() {
                    let pattern = raw.hasPrefix("~/") ? home.appendingPathComponent(String(raw.dropFirst(2))) : raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : directory.appendingPathComponent(raw)
                    if !raw.contains("*") && !raw.contains("?") { try read(pattern); continue }
                    let parent = pattern.deletingLastPathComponent()
                    guard fm.fileExists(atPath: parent.path) else { continue }
                    let regex = "^" + NSRegularExpression.escapedPattern(for: pattern.lastPathComponent).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
                    for file in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where file.lastPathComponent.range(of: regex, options: .regularExpression) != nil { try read(file) }
                }
            }
        }
        try read(directory.appendingPathComponent("config"))
        let known = directory.appendingPathComponent("known_hosts")
        if fm.fileExists(atPath: known.path) { knownHosts(try String(contentsOf: known, encoding: .utf8)).forEach { found.insert($0) } }
        return found.sorted { $0.localizedCompare($1) == .orderedAscending }
    }
}
