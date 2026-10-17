import Foundation

/// A workspace entry from `projects.listEntries` and `projects.searchEntries`
/// (`ProjectEntry`, packages/contracts/src/project.ts:265-270).
public struct ProjectEntry: Sendable, Equatable, Hashable {
    public var path: String
    public var isDirectory: Bool
    public var ignored: Bool
    public init(path: String, isDirectory: Bool, ignored: Bool = false) {
        self.path = path; self.isDirectory = isDirectory; self.ignored = ignored
    }

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// The parent folder, "" at the root.
    public var parent: String { path.lastIndex(of: "/").map { String(path[..<$0]) } ?? "" }
}

// MARK: - Preview modes

/// What the file tab shows for a path (FilePreviewPanel.tsx:1063-1068, packages/shared/src/filePreview.ts,
/// delimitedPreview.ts `filePreviewDelimiter`).
public enum FilePreviewKind: Equatable, Sendable {
    case image, video, audio, pdf, html
    case markdown
    case table(delimiter: Character)
    case text

    /// `WORKSPACE_IMAGE_PREVIEW_EXTENSIONS`.
    public static let imageExtensions = [".avif", ".gif", ".ico", ".jpeg", ".jpg", ".png", ".svg", ".webp"]
    /// `AUDIO_MIME_TYPE_BY_EXTENSION`.
    static let audioExtensions = [".mp3", ".wav", ".ogg", ".oga", ".flac", ".aac", ".m4a", ".opus", ".aiff"]
    /// `videoMimeType` (packages/shared/src/video.ts).
    static let videoExtensions = [".mp4", ".m4v", ".webm", ".mov", ".ogv"]

    public static func of(_ path: String) -> FilePreviewKind {
        let lower = path.lowercased()
        let ext = lower.lastIndex(of: ".").map { String(lower[$0...]) } ?? ""
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(where: { lower.hasSuffix($0) }) { return .image }
        if lower.hasSuffix(".pdf") { return .pdf }
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") { return .html }
        if lower.hasSuffix(".md") || lower.hasSuffix(".mdx") { return .markdown }
        if lower.hasSuffix(".csv") { return .table(delimiter: ",") }
        if lower.hasSuffix(".tsv") { return .table(delimiter: "\t") }
        return .text
    }

    /// Media and PDFs come from a signed asset URL; their text is never read (FilePreviewPanel.tsx:1072-1083).
    public var isAsset: Bool { [.image, .video, .audio, .pdf].contains(self) }
    /// Markdown, tables and HTML toggle between rendered and source.
    public var renderedToggle: (rendered: String, source: String)? {
        switch self {
        case .markdown: ("Show markdown source", "Show rendered markdown")
        case .table: ("Show source", "Show table")
        case .html: ("Show HTML source", "Show rendered page")
        default: nil
        }
    }
}

/// `filePreviewReadErrorMessage` (filePreviewMode.ts:13-31) for a `ProjectReadFileError.failure`.
public func filePreviewReadErrorMessage(failure: String?, operation: String?, message: String) -> String {
    switch failure {
    case "path_not_file": "The path is a directory or special file, not a regular file."
    case "binary_file": "The file is binary and cannot be displayed as text."
    case "workspace_path_outside_root": "The requested path is outside the workspace."
    case "resolved_path_outside_root": "The path resolves to a location outside the workspace."
    case "operation_failed":
        operation == "realpath-workspace-root" ? "The workspace folder could not be accessed."
            : "The file could not be accessed or read. It may be missing or inaccessible."
    default: message
    }
}

// MARK: - CSV and TSV

/// `parseDelimitedPreview` (packages/shared/src/delimitedPreview.ts): quoted delimiters, escaped
/// quotes and multiline cells; at most 100 rows, 30 columns and 2,000 characters a cell.
public enum DelimitedTable {
    public static func parse(_ text: String, delimiter: Character) -> (rows: [[String]], truncated: Bool) {
        let chars = Array(text.utf16)
        let delim = delimiter.utf16.first!
        var rows: [[String]] = []
        var row: [String] = []
        var cell: [UInt16] = []
        var quoted = false
        var truncated = false
        var index = chars.first == 0xFEFF ? 1 : 0
        var rowStart = index
        func endCell() {
            if row.count < 30 { row.append(String(decoding: cell, as: UTF16.self)) } else { truncated = true }
            cell.removeAll(keepingCapacity: true)
        }
        while index < chars.count {
            let c = chars[index]
            if c == 0x22 { // "
                if quoted, index + 1 < chars.count, chars[index + 1] == 0x22 {
                    if cell.count < 2000 { cell.append(0x22) } else { truncated = true }
                    index += 2
                    continue
                }
                if quoted || cell.isEmpty {
                    quoted.toggle()
                    index += 1
                    continue
                }
            }
            if !quoted, c == delim || c == 0x0A || c == 0x0D {
                endCell()
                if c != delim {
                    rows.append(row)
                    row = []
                    if c == 0x0D, index + 1 < chars.count, chars[index + 1] == 0x0A { index += 1 }
                    rowStart = index + 1
                    if rows.count == 100 { return (rows, truncated || index < chars.count - 1) }
                }
            } else if cell.count < 2000 {
                cell.append(c)
            } else {
                truncated = true
            }
            index += 1
        }
        if rowStart < chars.count {
            endCell()
            rows.append(row)
        }
        return (rows, truncated || quoted)
    }
}

// MARK: - Go to file

/// `getProjectFilePickerMatches` (ProjectFilePicker.logic.ts): the server already ranked the
/// entries, so this keeps its order, drops folders and marks the first ordered subsequence of the
/// query in the name and in the path (UTF-16 offsets).
public enum FilePicker {
    public static let resultLimit = 200

    public struct Match: Equatable, Sendable {
        public var name: String
        public var nameMatches: [Int]
        public var path: String
        public var pathMatches: [Int]
    }

    /// Compiled once: `normalize` runs on every keystroke of a file search.
    private static let leadingMarks = try! NSRegularExpression(pattern: "^[@./]+")

    public static func normalize(_ query: String) -> String {
        SearchRanking.normalize(query, trimLeading: leadingMarks).filter { !$0.isWhitespace }
    }

    static func matchIndices(_ value: String, _ query: String) -> [Int]? {
        if query.isEmpty { return [] }
        let v = Array(value.lowercased().utf16), q = Array(query.utf16)
        var out: [Int] = []
        var k = 0
        for (i, c) in v.enumerated() where c == q[k] {
            out.append(i)
            k += 1
            if k == q.count { return out }
        }
        return nil
    }

    public static func matches(_ entries: [ProjectEntry], query rawQuery: String, limit: Int = resultLimit) -> [Match] {
        guard limit > 0 else { return [] }
        let query = normalize(rawQuery)
        var out: [Match] = []
        for entry in entries where !entry.isDirectory {
            out.append(Match(name: entry.name, nameMatches: matchIndices(entry.name, query) ?? [],
                             path: entry.path, pathMatches: matchIndices(entry.path, query) ?? []))
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - Breadcrumbs

/// `fileBreadcrumbs`, `fileBreadcrumbChildren` and `fileBreadcrumbParent` (components/files/filePath.ts).
public enum FileBreadcrumbs {
    public struct Crumb: Equatable, Sendable {
        public enum Kind: Sendable { case project, directory, file }
        public var label: String
        public var path: String
        public var kind: Kind
    }

    public static func crumbs(projectName: String, path: String) -> [Crumb] {
        let host = path.hasPrefix("/")
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        var out: [Crumb] = host ? [Crumb(label: "/", path: "/", kind: parts.isEmpty ? .file : .directory)] : [Crumb(label: projectName, path: "", kind: .project)]
        for (i, part) in parts.enumerated() {
            out.append(Crumb(label: part, path: (host ? "/" : "") + parts[...i].joined(separator: "/"),
                             kind: i == parts.count - 1 ? .file : .directory))
        }
        return out
    }

    /// A folder's direct children, folders first, then by name with numbers compared as numbers.
    public static func children(_ entries: [ProjectEntry], of directory: String) -> [ProjectEntry] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        return entries.filter { e in
            guard e.path.hasPrefix(prefix) else { return false }
            let rest = e.path.dropFirst(prefix.count)
            return !rest.isEmpty && !rest.contains("/")
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.compare(b.name, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }

    public static func parent(_ directory: String) -> String? {
        guard !directory.isEmpty else { return nil }
        return directory.lastIndex(of: "/").map { String(directory[..<$0]) } ?? ""
    }
}

// MARK: - Line reveal

/// `clampFileLine` (FilePreviewPanel.tsx:381-393): CR, LF and CRLF each end a line.
public func clampFileLine(_ contents: String, _ requested: Int) -> Int {
    var count = 1
    var previousCR = false
    for c in contents.utf16 {
        if c == 0x0A { if !previousCR { count += 1 }; previousCR = false }
        else if c == 0x0D { count += 1; previousCR = true }
        else { previousCR = false }
    }
    return min(max(1, requested), count)
}

// MARK: - Saving

/// `FileSaveCoordinator` (components/files/fileSaveCoordinator.ts): debounced autosave, one write
/// at a time, newest contents win. A write that finishes after newer edits schedules the next one
/// for the rest of the debounce; `pending` turns false only when the newest revision is confirmed.
/// `onConfirmed` returning false (another editor holds newer unsaved text) keeps it pending.
@MainActor
public final class FileSaveCoordinator {
    /// `FILE_SAVE_DEBOUNCE_MS`.
    public static let debounce: TimeInterval = 0.5

    public let debounceInterval: TimeInterval
    private let persist: @MainActor (String) async -> Bool
    private let onPendingChange: (Bool) -> Void
    private let onConfirmed: (String) -> Bool
    private let canPersist: () -> Bool
    private var timer: Task<Void, Never>?
    private var latestContents = ""
    private var latestRevision = 0
    private var confirmedRevision = 0
    private var lastChangeAt = Date.distantPast
    private var saving = false
    private var disposed = false

    public init(debounce: TimeInterval = FileSaveCoordinator.debounce, canPersist: @escaping () -> Bool = { true },
                persist: @escaping @MainActor (String) async -> Bool, onPendingChange: @escaping (Bool) -> Void,
                onConfirmed: @escaping (String) -> Bool = { _ in true }) {
        debounceInterval = debounce
        self.persist = persist; self.onPendingChange = onPendingChange
        self.onConfirmed = onConfirmed; self.canPersist = canPersist
    }

    public var hasUnsaved: Bool { latestRevision != confirmedRevision }

    public func change(_ contents: String) {
        guard !disposed else { return }
        latestContents = contents
        latestRevision += 1
        lastChangeAt = Date()
        onPendingChange(true)
        schedule(debounceInterval)
    }

    /// Flushes the newest contents now (the tab closes or the thread changes).
    public func dispose() {
        disposed = true
        timer?.cancel()
        timer = nil
        if latestRevision > 0 { Task { await persistLatest() } }
    }

    private func schedule(_ delay: TimeInterval) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.persistLatest()
        }
    }

    func persistLatest() async {
        guard !saving, latestRevision != confirmedRevision, canPersist() else { return }
        saving = true
        let contents = latestContents, revision = latestRevision
        let succeeded = await persist(contents)
        var confirmed = false
        if succeeded {
            confirmedRevision = revision
            confirmed = onConfirmed(contents)
        }
        saving = false
        if revision == latestRevision {
            if confirmed { onPendingChange(false) }
            return
        }
        let remaining = max(0, debounceInterval - Date().timeIntervalSince(lastChangeAt))
        if disposed { await persistLatest() } else { schedule(remaining) }
    }
}
