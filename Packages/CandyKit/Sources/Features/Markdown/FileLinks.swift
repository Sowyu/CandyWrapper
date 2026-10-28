import Foundation

/// A file path that T3 renders as a chip in chat markdown (`MarkdownFileLinkMeta`, apps/web/src/markdown-links.ts).
/// Ported from packages/shared/src/markdownLinks.ts, fileLinks.ts and path.ts and apps/web/src/markdown-links.ts.
public struct FileLinkMeta: Sendable, Equatable {
    /// The path without its `:line:column` suffix.
    public var filePath: String
    /// The resolved path with the suffix: the chip's tooltip and "Copy full path".
    public var targetPath: String
    /// Path inside the workspace, `nil` outside it (T3 opens these in the files panel).
    public var workspaceRelativePath: String?
    public var basename: String
    public var line: Int?
    public var column: Int?

    /// `inferEntryKindFromPath` (pierre-icons.ts:152): a folder icon when the last segment has no dot,
    /// or is a dot name like `.git`.
    public var isDirectory: Bool {
        let base = filePath.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? filePath
        if base.hasPrefix("."), !base.dropFirst().contains(".") { return true }
        return !base.contains(".")
    }

    /// What T3's files panel opens on a plain click (ChatMarkdown.tsx `fileLinkChip`): the
    /// workspace-relative path, or the absolute host path for a non-media file outside the workspace.
    public var panelPath: String? {
        if let workspaceRelativePath { return workspaceRelativePath }
        return FileLinks.isAbsolutePath(filePath) ? filePath : nil
    }
}

public enum FileLinks {
    // MARK: Inline code

    /// `inlineCodeFilePathCandidate` (markdownLinks.ts): path-shaped inline code. Needs an explicit
    /// path prefix, or a separator plus an extension, or a `:line` suffix; hosts and versions are out.
    public static func inlineCodeCandidate(_ codeText: String) -> String? {
        let trimmed = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(where: { $0.isWhitespace || $0 == "`" }) { return nil }
        let candidate = isWindowsAbsolutePath(trimmed) ? trimmed : trimmed.replacingOccurrences(of: "\\", with: "/")
        let hasPosition = matches(positionSuffix, candidate)
        if !hasPosition, !candidate.contains("/"), !candidate.contains("\\") { return nil }
        let explicit = matches(relativePrefix, candidate) || candidate.hasPrefix("/") || isWindowsAbsolutePath(candidate)
        if !explicit {
            let withoutPosition = replace(positionSuffix, in: candidate)
            // Markdown destinations accept `patches/`; inline code still needs a file-shaped last segment (6de7da548d).
            if withoutPosition.hasSuffix("/") { return nil }
            let firstSegment = withoutPosition.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? withoutPosition
            if looksLikeHostname(firstSegment, hasPosition: hasPosition) { return nil }
            var base = withoutPosition
            while base.hasSuffix("/") || base.hasSuffix("\\") { base.removeLast() }
            base = base.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            if matches(versionSuffix, base) { return nil }
            if !hasPosition, !matches(fileExtension, base) { return nil }
        }
        return candidate
    }

    /// `resolveInlineCodeFileLinkMeta` (markdown-links.ts). `cwd` is the thread's worktree or the project root.
    public static func resolveInlineCode(_ codeText: String, cwd: String?) -> FileLinkMeta? {
        guard let candidate = inlineCodeCandidate(codeText) else { return nil }
        // Chat messages anchor relative paths at the workspace root (baseDir == cwd), so the
        // "names from the workspace root" rule picks the same base either way.
        // T3 validates the candidate as a Markdown destination before resolving it
        // (apps/web/src/markdown-links.ts:47-54). A leading slash alone is not enough.
        return resolveLink(candidate, cwd: cwd)
    }

    // MARK: Links

    /// `parseMarkdownFileLink` (markdownLinks.ts): a link destination that names a file, not a route or a site.
    public static func parseLink(_ href: String) -> (path: String, line: Int?, column: Int?)? {
        var normalized = href.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("<"), normalized.hasSuffix(">") { normalized = String(normalized.dropFirst().dropLast()) }
        if normalized.isEmpty || normalized.hasPrefix("#") || normalized.hasPrefix("//") { return nil }
        var rawPath: String, rawHash: String
        if normalized.lowercased().hasPrefix("file:"), let url = URL(string: normalized), url.scheme?.lowercased() == "file" {
            let host = url.host ?? ""
            let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            rawPath = host.isEmpty || host.lowercased() == "localhost" ? encodedPath : "\\\\\(host)\(encodedPath.replacingOccurrences(of: "/", with: "\\"))"
            rawHash = url.fragment.map { "#\($0)" } ?? ""
            if rawPath.isEmpty { return nil }
        } else {
            let hashIndex = normalized.firstIndex(of: "#")
            let beforeHash = hashIndex.map { String(normalized[..<$0]) } ?? normalized
            rawHash = hashIndex.map { String(normalized[$0...]) } ?? ""
            rawPath = beforeHash.firstIndex(of: "?").map { String(beforeHash[..<$0]) } ?? beforeHash
        }
        let path = stripSlashPrefixedWindowsDrive((rawPath.trimmingCharacters(in: .whitespaces).removingPercentEncoding) ?? rawPath.trimmingCharacters(in: .whitespaces))
        let hash = rawHash.trimmingCharacters(in: .whitespaces).removingPercentEncoding ?? rawHash
        if path.isEmpty || hasExternalScheme(path) { return nil }
        let position = splitPosition(path, hash: hash)
        return looksLikeFilePath(position.path, authored: path) ? position : nil
    }

    /// `resolveMarkdownFileLinkMeta` for a link destination.
    public static func resolveLink(_ href: String, cwd: String?) -> FileLinkMeta? {
        guard let target = parseLink(href) else { return nil }
        return resolve(format(target.path, target.line, target.column), cwd: cwd)
    }

    /// `isMarkdownFileLinkLabel` (markdownLinks.ts): the label already names the file, so T3 shows only the chip.
    public static func isFileLinkLabel(_ label: String, href: String) -> Bool {
        guard let destination = parseLink(href) else { return false }
        func normalize(_ p: String) -> String {
            var s = p.replacingOccurrences(of: "\\", with: "/")
            if s.hasPrefix("./") { s.removeFirst(2) }
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        let labelPosition = splitPosition(label.trimmingCharacters(in: .whitespacesAndNewlines))
        if let l = labelPosition.line, l != destination.line { return false }
        if let c = labelPosition.column, c != destination.column { return false }
        var labelPath = normalize(labelPosition.path), destinationPath = normalize(destination.path)
        if labelPath.isEmpty { return true }
        if isWindowsAbsolutePath(destination.path) { labelPath = labelPath.lowercased(); destinationPath = destinationPath.lowercased() }
        return destinationPath == labelPath || destinationPath.hasSuffix("/" + labelPath)
    }

    // MARK: Labels

    /// `buildFileLinkParentSuffixByPath` (fileLinks.ts): parent folders that tell same-named files apart
    /// within one message, at least two segments deep.
    public static func parentSuffixes(_ filePaths: [String]) -> [String: String] {
        var groups: [String: [String]] = [:]
        for filePath in filePaths {
            let normalized = filePath.replacingOccurrences(of: "\\", with: "/")
            guard let base = normalized.split(separator: "/").last.map(String.init) else { continue }
            if groups[base]?.contains(normalized) != true { groups[base, default: []].append(normalized) }
        }
        var out: [String: String] = [:]
        for paths in groups.values where paths.count >= 2 {
            let parents = Dictionary(uniqueKeysWithValues: paths.map { ($0, $0.split(separator: "/").map(String.init).dropLast().map { $0 }) })
            for path in paths {
                let segments = parents[path] ?? []
                guard !segments.isEmpty else { continue }
                var depth = segments.count
                for d in 1...segments.count {
                    let candidate = segments.suffix(d)
                    let collision = paths.contains { $0 != path && Array((parents[$0] ?? []).suffix(d)) == Array(candidate) }
                    if !collision { depth = d; break }
                }
                let suffixDepth = min(segments.count, max(depth, 2))
                out[path] = segments.suffix(suffixDepth).joined(separator: "/")
            }
        }
        return out
    }

    /// `fileLinkLabel` (fileLinks.ts): basename, the disambiguating parents, then `L12:C3`.
    public static func label(_ meta: FileLinkMeta, suffixes: [String: String]) -> String {
        var parts = [meta.basename]
        if let suffix = suffixes[meta.filePath.replacingOccurrences(of: "\\", with: "/")] { parts.append(suffix) }
        if let line = meta.line { parts.append("L\(line)" + (meta.column.map { ":C\($0)" } ?? "")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Resolution

    static func resolve(_ pathWithPosition: String, cwd: String?) -> FileLinkMeta? {
        let target: String
        if isRelativeFilePath(pathWithPosition) {
            guard let cwd else { return nil }
            target = resolveAgainst(pathWithPosition, cwd: cwd)
        } else {
            target = pathWithPosition
        }
        let position = splitPosition(target)
        return FileLinkMeta(filePath: position.path, targetPath: target,
                            workspaceRelativePath: workspaceRelative(position.path, root: cwd),
                            basename: basename(position.path), line: position.line, column: position.column)
    }

    /// `resolvePathLinkTarget` (fileLinks.ts:91-108): `~/`, or `~\` under a Windows cwd, from the home inferred
    /// from cwd, else joined onto cwd.
    public static func resolveAgainst(_ raw: String, cwd: String) -> String {
        let position = splitPosition(raw)
        var path = position.path
        if path.hasPrefix("~/") || (isWindowsStyle(cwd) && path.hasPrefix("~\\")) {
            if let home = inferHome(cwd) { path = join(home, String(path.dropFirst(2)), windows: isWindowsStyle(home)) }
        } else if !isAbsolutePath(path) {
            path = join(cwd, path, windows: isWindowsStyle(cwd))
        }
        return format(path, position.line, position.column)
    }

    static func inferHome(_ cwd: String) -> String? {
        for prefix in ["/Users/", "/home/"] where cwd.hasPrefix(prefix) {
            let user = cwd.dropFirst(prefix.count).prefix { $0 != "/" }
            if !user.isEmpty { return prefix + user }
        }
        let parts = cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if parts.count >= 3, isWindowsDrivePath(String(parts[0]) + "/"), parts[1].lowercased() == "users" {
            return "\(parts[0])\\\(parts[1])\\\(parts[2])"
        }
        return nil
    }

    static func join(_ base: String, _ next: String, windows: Bool) -> String {
        var clean = base
        while clean.hasSuffix("/") || clean.hasSuffix("\\") { clean.removeLast() }
        if windows { return clean + "\\" + next.replacingOccurrences(of: "/", with: "\\") }
        var tail = Substring(next)
        while tail.hasPrefix("/") { tail = tail.dropFirst() }
        return clean + "/" + tail
    }

    static func isWindowsStyle(_ value: String) -> Bool {
        isWindowsAbsolutePath(value) || value.range(of: #"[A-Za-z]:\\"#, options: .regularExpression) != nil
    }

    /// `splitFilePathPosition` (fileLinks.ts): `:12` or `:12:3` at the end, else a `#L12C3` hash.
    static func splitPosition(_ path: String, hash: String = "") -> (path: String, line: Int?, column: Int?) {
        let ns = path as NSString
        if let m = positionCapture.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)) {
            let line = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let column = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) : nil
            return (ns.substring(to: m.range.location), line > 0 ? line : nil, (column ?? 0) > 0 ? column : nil)
        }
        let h = hash as NSString
        if let m = positionHash.firstMatch(in: hash, range: NSRange(location: 0, length: h.length)) {
            let line = Int(h.substring(with: m.range(at: 1))) ?? 0
            let column = m.range(at: 2).location != NSNotFound ? Int(h.substring(with: m.range(at: 2))) : nil
            return (path, line > 0 ? line : nil, (column ?? 0) > 0 ? column : nil)
        }
        return (path, nil, nil)
    }

    static func format(_ path: String, _ line: Int?, _ column: Int?) -> String {
        guard let line else { return path }
        return "\(path):\(line)" + (column.map { ":\($0)" } ?? "")
    }

    // MARK: Path shapes

    static func looksLikeFilePath(_ path: String, authored: String) -> Bool {
        if isWindowsAbsolutePath(path) || matches(relativePrefix, path) { return true }
        if path.hasPrefix("/") { return looksLikePosixFilesystemPath(authored) }
        if extensionlessNames.contains(path) { return true }
        return matches(relativeFilePath, authored) || matches(relativeFileName, path)
    }

    static func looksLikePosixFilesystemPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if posixRoots.contains(where: { path.hasPrefix($0) }) { return true }
        if matches(positionSuffix, path) { return true }
        let base = String(path[path.index(after: path.lastIndex(of: "/")!)...])
        return extensionlessNames.contains(base) || matches(fileExtension, base)
    }

    static func hasExternalScheme(_ path: String) -> Bool {
        if isWindowsAbsolutePath(path) { return false }
        let ns = path as NSString
        guard let m = externalScheme.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)) else { return false }
        let rest = ns.substring(with: m.range(at: 2))
        if rest.hasPrefix("//") { return true }
        return !matches(positionOnly, rest)
    }

    static func looksLikeHostname(_ segment: String, hasPosition: Bool) -> Bool {
        if segment.hasPrefix(".") { return false }
        let lowered = segment.lowercased()
        if lowered == "localhost" { return true }
        if matches(numericDotted, segment) { return true }
        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last.map(String.init) else { return false }
        if genericTLDs.contains(last) { return true }
        return !hasPosition && countryTLDs.contains(last)
    }

    public static func isRelativeFilePath(_ path: String) -> Bool {
        matches(relativePrefix, path) || (!path.hasPrefix("/") && !isWindowsAbsolutePath(path))
    }

    public static func isAbsolutePath(_ value: String) -> Bool { value.hasPrefix("/") || isWindowsAbsolutePath(value) }
    static func isWindowsDrivePath(_ value: String) -> Bool { matches(windowsDrive, value) }
    static func isWindowsAbsolutePath(_ value: String) -> Bool { value.hasPrefix("\\\\") || isWindowsDrivePath(value) }

    static func stripSlashPrefixedWindowsDrive(_ path: String) -> String {
        matches(slashDrive, path) ? String(path.dropFirst()) : path
    }

    /// `fileBasename` (path.ts): trailing separators trimmed first so a folder keeps its name.
    static func basename(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed = trimmed.dropLast() }
        if trimmed.isEmpty { return path }
        if let i = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) { return String(trimmed[trimmed.index(after: i)...]) }
        return String(trimmed)
    }

    /// `workspaceRelativeFilePath` (path.ts:85-110): "." for the root itself, nil outside it.
    static func workspaceRelative(_ path: String, root: String?) -> String? {
        guard let root, !root.isEmpty else { return nil }
        let p = stripSlashPrefixedWindowsDrive(path.replacingOccurrences(of: "\\", with: "/"))
        var r = stripSlashPrefixedWindowsDrive(root.replacingOccurrences(of: "\\", with: "/"))
        while r.hasSuffix("/") { r.removeLast() }
        let insensitive = isWindowsAbsolutePath(stripSlashPrefixedWindowsDrive(root))
        let pc = insensitive ? p.lowercased() : p, rc = insensitive ? r.lowercased() : r
        var trimmed = pc
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == rc { return "." }
        guard pc.hasPrefix(rc + "/") else { return nil }
        let relative = String(p.dropFirst(r.count + 1))
        // `/repo/../x` starts with the root but escapes it, so it opens as a host file (edce5f0e53).
        var depth = 0
        for segment in relative.split(separator: "/", omittingEmptySubsequences: false) {
            if segment == ".." { depth -= 1 } else if !segment.isEmpty, segment != "." { depth += 1 }
            if depth < 0 { return nil }
        }
        return relative
    }

    /// `mediaMimeTypeFromExtension` != null (filePreview.ts): images, video and audio open in the media viewer.
    static func isMedia(_ basename: String) -> Bool {
        guard let dot = basename.lastIndex(of: ".") else { return false }
        return mediaExtensions.contains(basename[basename.index(after: dot)...].lowercased())
    }

    // MARK: Tables

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
    private static func replace(_ r: NSRegularExpression, in s: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    nonisolated(unsafe) static let relativePrefix = regex(#"^(~/|\.{1,2}/)"#)
    /// The last segment is optional, so a folder link may end in `/` (`patches/`); a bare name still fails (6de7da548d).
    nonisolated(unsafe) static let relativeFilePath = regex(#"^(?:[A-Za-z0-9._-]+(?: +[A-Za-z0-9._-]+)*/)+(?:[A-Za-z0-9._-]+(?: +[A-Za-z0-9._-]+)*(?::\d+){0,2})?$"#)
    nonisolated(unsafe) static let relativeFileName = regex(#"^[A-Za-z0-9._-]+(?: +[A-Za-z0-9._-]+)*\.[A-Za-z0-9_-]+(?::\d+){0,2}$"#)
    nonisolated(unsafe) static let externalScheme = regex(#"^([A-Za-z][A-Za-z0-9+.-]*):(.*)$"#)
    nonisolated(unsafe) static let positionSuffix = regex(#":\d+(?::\d+)?$"#)
    nonisolated(unsafe) static let positionCapture = regex(#":(\d+)(?::(\d+))?$"#)
    nonisolated(unsafe) static let positionHash = try! NSRegularExpression(pattern: #"^#L(\d+)(?:C(\d+))?$"#, options: .caseInsensitive)
    nonisolated(unsafe) static let positionOnly = regex(#"^\d+(?::\d+)?$"#)
    nonisolated(unsafe) static let fileExtension = regex(#"\.[A-Za-z0-9_-]+$"#)
    nonisolated(unsafe) static let versionSuffix = regex(#"\d\.\d[^.]*$"#)
    nonisolated(unsafe) static let numericDotted = regex(#"^\d+(?:\.\d+)+$"#)
    nonisolated(unsafe) static let windowsDrive = regex(#"^[a-zA-Z]:([/\\]|$)"#)
    nonisolated(unsafe) static let slashDrive = regex(#"^/[A-Za-z]:[\\/]"#)

    static let posixRoots = ["/Users/", "/home/", "/tmp/", "/var/", "/etc/", "/opt/", "/mnt/", "/Volumes/", "/private/", "/root/",
                             "/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/", "/srv/", "/dev/", "/proc/", "/sys/", "/run/", "/boot/",
                             "/media/", "/workspace/", "/workspaces/"]
    static let extensionlessNames: Set<String> = [
        "Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile", "Justfile", "justfile", "Rakefile", "Gemfile",
        "Procfile", "Brewfile", "Caddyfile", "Vagrantfile", "Jenkinsfile", "Podfile", "Fastfile", "BUILD", "WORKSPACE",
        "LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS", "CONTRIBUTORS", "CHANGELOG", "README", "CODEOWNERS"]
    static let genericTLDs: Set<String> = ["com", "net", "org", "io", "dev", "app", "ai", "co", "edu", "gov", "mil", "info", "biz",
                                           "xyz", "me", "tv", "cc", "gg", "chat", "cloud", "site", "online", "tech", "store", "link"]
    static let countryTLDs: Set<String> = ["uk", "de", "fr", "nl", "se", "no", "fi", "dk", "pl", "ch", "at", "be", "es", "it", "pt",
                                           "eu", "us", "ca", "au", "nz", "jp", "kr", "cn", "br", "ru", "mx", "ie", "cz", "tr", "sg", "hk"]
    /// filePreview.ts IMAGE_MIME_TYPE_BY_EXTENSION and video.ts VIDEO_MIME_TYPE_BY_EXTENSION.
    static let mediaExtensions: Set<String> = ["avif", "gif", "ico", "jpeg", "jpg", "png", "svg", "webp",
                                               "avi", "m4v", "mkv", "mov", "mp4", "ogv", "webm"]
}
