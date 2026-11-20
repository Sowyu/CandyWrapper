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

    public init(filePath: String, targetPath: String, workspaceRelativePath: String?, basename: String, line: Int?, column: Int?) {
        self.filePath = filePath; self.targetPath = targetPath; self.workspaceRelativePath = workspaceRelativePath
        self.basename = basename; self.line = line; self.column = column
    }

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

    /// `inlineCodeFilePathCandidate` (4928 shared/src/markdownLinks.ts:201-243): path-shaped inline code. Needs an
    /// explicit path prefix, or a separator plus an extension or a known extensionless name (`docker/Dockerfile`,
    /// #32402), or a `:line` suffix; hosts, versions and paths shortened with `...` (#30762) are out. Spaces only
    /// in an absolute path of plain names (#37750).
    public static func inlineCodeCandidate(_ codeText: String) -> String? {
        let trimmed = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("`") { return nil }
        if trimmed.contains(where: \.isWhitespace), !isSpacedAbsoluteFilePath(trimmed) { return nil }
        let candidate = isWindowsAbsolutePath(trimmed) ? trimmed : trimmed.replacingOccurrences(of: "\\", with: "/")
        let hasPosition = matches(positionSuffix, candidate)
        if !hasPosition, !candidate.contains("/"), !candidate.contains("\\") { return nil }
        if matches(elidedSegment, replace(positionSuffix, in: candidate)) { return nil }
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
            if !matches(fileExtension, base) {
                if !hasPosition { return extensionlessNames.contains(base) ? candidate : nil }
                // A `:line` suffix alone does not make `I/W217:220` a file reference.
                if withoutPosition.contains("/"), !matches(anyFileExtension, base), !extensionlessNames.contains(base) { return nil }
            }
        }
        return candidate
    }

    /// `isSpacedAbsoluteFilePath` (markdownLinks.ts:43-57): `/Users/me/Mobile Documents/a - b.md` is a file,
    /// `/usr/bin/python3 -m venv .venv` and `/usr/local/bin/node server.js` are commands.
    static func isSpacedAbsoluteFilePath(_ text: String) -> Bool {
        let ns = text as NSString
        guard let root = spacedRoot.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return false }
        let rootText = ns.substring(with: root.range)
        let body = replace(positionSuffix, in: ns.substring(from: root.range.length))
        guard matches(spacedBody, body), let space = body.firstIndex(of: " ") else { return false }
        let isSeparator = { (c: Character) in c == "/" || c == "\\" }
        let folders = body[..<space].split(omittingEmptySubsequences: false, whereSeparator: isSeparator).dropLast()
        if folders.contains(where: { $0 == "bin" || $0 == "sbin" }) { return false }
        let spaceInFolder = body[space...].contains(where: isSeparator)
        if !spaceInFolder, rootText == "/", !(body.hasPrefix("Users/") || body.hasPrefix("home/") || body.hasPrefix("Users\\") || body.hasPrefix("home\\")) { return false }
        if let last = body.last, isSeparator(last) { return true }
        let base = body.split(omittingEmptySubsequences: false, whereSeparator: isSeparator).last.map(String.init) ?? ""
        return matches(fileExtension, base) || extensionlessNames.contains(base)
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
        // `src\a.ts` is Windows-relative: a path that doesn't parse as written tries again with `/` (markdownLinks.ts:342-360, #33643).
        if let position = filePosition(path, hash: hash) { return position }
        if path.hasPrefix("/") || path.hasPrefix("\\") || isWindowsAbsolutePath(path) || !path.contains("\\") { return nil }
        return filePosition(path.replacingOccurrences(of: "\\", with: "/"), hash: hash)
    }

    private static func filePosition(_ path: String, hash: String) -> (path: String, line: Int?, column: Int?)? {
        let position = splitPosition(path, hash: hash)
        return !matches(elidedSegment, position.path) && looksLikeFilePath(position.path, authored: path) ? position : nil
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
        // A range's end line in the label must match the destination's too (markdownLinks.ts at 4928, #34006).
        if let end = endLine(label.trimmingCharacters(in: .whitespacesAndNewlines)), end != endLine(href) { return false }
        var labelPath = normalize(labelPosition.path), destinationPath = normalize(destination.path)
        if labelPath.isEmpty { return true }
        if isWindowsAbsolutePath(destination.path) { labelPath = labelPath.lowercased(); destinationPath = destinationPath.lowercased() }
        return destinationPath == labelPath || destinationPath.hasSuffix("/" + labelPath)
    }

    // MARK: Labels

    /// `buildFileLinkParentSuffixByPath` (fileLinks.ts): parent folders that tell same-named files apart
    /// within one message, at least two segments deep. Each path's depth is the first suffix no other path of
    /// its name shares, read from one count of every suffix (fileLinks.ts at 4928, #34340), not a scan of every
    /// other path per depth.
    public static func parentSuffixes(_ filePaths: [String]) -> [String: String] {
        var groups: [String: [String]] = [:]
        var seen = Set<String>()
        for filePath in filePaths {
            let normalized = filePath.replacingOccurrences(of: "\\", with: "/")
            guard let base = normalized.split(separator: "/").last.map(String.init), seen.insert(normalized).inserted else { continue }
            groups[base, default: []].append(normalized)
        }
        var out: [String: String] = [:]
        for paths in groups.values where paths.count >= 2 {
            let parents = paths.map { $0.split(separator: "/").dropLast().map(String.init) }
            var suffixCounts: [String: Int] = [:]
            for segments in parents where !segments.isEmpty {
                for d in 1...segments.count { suffixCounts[segments.suffix(d).joined(separator: "/"), default: 0] += 1 }
            }
            for (path, segments) in zip(paths, parents) where !segments.isEmpty {
                let depth = (1...segments.count).first { suffixCounts[segments.suffix($0).joined(separator: "/")] == 1 } ?? segments.count
                out[path] = segments.suffix(min(segments.count, max(depth, 2))).joined(separator: "/")
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

    /// The last line of a range such as `:42-64` or `#L42-L64`, when it is past the first (fileLinks.ts at 4928, #34006).
    static func endLine(_ text: String) -> Int? {
        let hashIndex = text.firstIndex(of: "#")
        let path = hashIndex.map { String(text[..<$0]) } ?? text
        let hash = hashIndex.map { String(text[$0...]) } ?? ""
        for (pattern, value) in [(positionCapture, path), (positionHash, hash)] {
            let ns = value as NSString
            guard let m = pattern.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { continue }
            guard m.range(at: 3).location != NSNotFound, let line = Int(ns.substring(with: m.range(at: 1))),
                  let end = Int(ns.substring(with: m.range(at: 3))), line > 0, end > line else { return nil }
            return end
        }
        return nil
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
    /// T3 3814 packages/shared/src/markdownLinks.ts:17-25 accepts names in every script.
    nonisolated(unsafe) static let relativeFilePath = regex(#"^(?:[\p{L}\p{M}\p{N}._$+@()\[\]-]+(?: +[\p{L}\p{M}\p{N}._$+@()\[\]-]+)*/)+(?:[\p{L}\p{M}\p{N}._$+@()\[\]-]+(?: +[\p{L}\p{M}\p{N}._$+@()\[\]-]+)*(?::\d+(?::\d+|-\d+)?)?)?$"#)
    nonisolated(unsafe) static let relativeFileName = regex(#"^[\p{L}\p{M}\p{N}._$+()\[\]-]+(?: +[\p{L}\p{M}\p{N}._$+()\[\]-]+)*\.[\p{L}\p{M}\p{N}_-]+(?::\d+(?::\d+|-\d+)?)?$"#)
    nonisolated(unsafe) static let externalScheme = regex(#"^([A-Za-z][A-Za-z0-9+.-]*):(.*)$"#)
    nonisolated(unsafe) static let positionSuffix = regex(#":\d+(?::\d+|-\d+)?$"#)
    nonisolated(unsafe) static let positionCapture = regex(#":(\d+)(?::(\d+)|-(\d+))?$"#)
    nonisolated(unsafe) static let positionHash = try! NSRegularExpression(pattern: #"^#L(\d+)(?:C(\d+)|-L?(\d+))?$"#, options: .caseInsensitive)
    nonisolated(unsafe) static let positionOnly = regex(#"^\d+(?::\d+|-\d+)?$"#)
    /// Agents shorten long paths with a `...` or `…` segment, which no chip can open.
    nonisolated(unsafe) static let elidedSegment = regex(#"(?:^|[\\/])(?:\.{3,}|…)(?:[\\/]|$)"#)
    nonisolated(unsafe) static let anyFileExtension = regex(#"\.[^./\\]+$"#)
    nonisolated(unsafe) static let spacedRoot = regex(#"^(?:/|~/|[A-Za-z]:[\\/])"#)
    nonisolated(unsafe) static let spacedBody = regex(#"^(?:[\p{L}\p{M}\p{N}._$+@()\[\]-]+(?: (?!-+\p{L})[\p{L}\p{M}\p{N}._$+@()\[\]-]+)*(?:[\\/]|$))+$"#)
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
                                           "xyz", "me", "tv", "gg", "chat", "cloud", "site", "online", "tech", "store", "link"]
    static let countryTLDs: Set<String> = ["uk", "de", "fr", "nl", "se", "no", "fi", "dk", "pl", "ch", "at", "be", "es", "it", "pt",
                                           "eu", "us", "ca", "au", "nz", "jp", "kr", "cn", "br", "ru", "mx", "ie", "cz", "tr", "sg", "hk", "cc"]
    /// filePreview.ts IMAGE_MIME_TYPE_BY_EXTENSION and video.ts VIDEO_MIME_TYPE_BY_EXTENSION.
    static let mediaExtensions: Set<String> = ["avif", "gif", "ico", "jpeg", "jpg", "png", "svg", "webp",
                                               "avi", "m4v", "mkv", "mov", "mp4", "ogv", "webm"]
}
