import Foundation
import T3Protocol
import T3Store

/// The shape your message takes (TimelineUserMessageRow.tsx:460-575 at 4928, #27306, #27324, #27377): images and
/// videos sent without words show as media with no bubble, and with words they sit above the bubble. Files sent
/// without words show as cards, and a voice note alone shows as its own bubble. Messages from agents and guests
/// keep the bubble around everything.
struct UserMessageShape: Equatable {
    var images: [JSONValue] = []
    var videos: [JSONValue] = []
    var audio: [JSONValue] = []
    /// Files other than video and audio, with or without a chip in the text.
    var files: [JSONValue] = []
    /// Files with no chip in the text, and attachments of an unknown type.
    var unchippedFiles: [JSONValue] = []
    var mediaOnly = false
    var mediaAboveText = false
    var fileCardsOnly = false
    var audioOnly = false

    var standaloneMedia: Bool { mediaOnly || mediaAboveText }
    /// The bubble keeps its fill and padding.
    var drawsBubble: Bool { !mediaOnly && !fileCardsOnly && !audioOnly }
    /// A lone image keeps its own shape; a 4:3 crop hides most of a wide screenshot.
    var loneImage: Bool { standaloneMedia && videos.isEmpty && images.count == 1 }
    /// Several images share one rounded shape, split by hairlines.
    var collage: Bool {
        standaloneMedia && videos.isEmpty && images.count > 1 && images.allSatisfy { $0["source"]?["kind"]?.stringValue != "snap-shot" }
    }

    init() {}

    /// `own`: neither folded (another agent's) nor a guest's.
    init(_ m: ChatMessage, text: String, own: Bool) {
        var chipped: [String: String] = [:] // contextId: attachmentId
        if case .array(let records)? = m.context?["records"] {
            for r in records where ["file", "image"].contains(r["kind"]?.stringValue ?? "") {
                if let context = r["contextId"]?.stringValue, let attachment = r["attachmentId"]?.stringValue { chipped[context] = attachment }
            }
        }
        let tokens = ComposerInlineTokens.collect(text)
        var referenced = Set<String>()
        for t in tokens { if case .context(_, let id, _) = t.kind, let attachment = chipped[id] { referenced.insert(attachment) } }
        var unknown = 0
        for a in m.attachments {
            let type = a["type"]?.stringValue ?? "", name = a["name"]?.stringValue ?? "", mime = a["mimeType"]?.stringValue ?? ""
            if type == "image" {
                if !name.hasPrefix("preview-annotation-") { images.append(a) }
            } else if type == "file" {
                if isPlayableVideoMime(mime) { videos.append(a) }
                else if a["downloadable"] != .bool(false), InlineAudioSource.isAudio(name: name, mimeType: mime) { audio.append(a) }
                else {
                    files.append(a)
                    if !referenced.contains(a["id"]?.stringValue ?? "") { unchippedFiles.append(a) }
                }
            } else {
                unknown += 1
                unchippedFiles.append(a)
            }
        }
        let media = images.count + videos.count
        mediaOnly = own && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && audio.isEmpty && unchippedFiles.isEmpty && media > 0
        mediaAboveText = own && !mediaOnly && media > 0
        /// The text once the chips of `kept` attachments go and other chips read as their labels.
        func residue(without kept: [JSONValue]) -> String {
            let ids = Set(kept.compactMap { $0["id"]?.stringValue })
            let ns = NSMutableString(string: text)
            for t in tokens.reversed() {
                guard case .context(_, let id, let label) = t.kind else { continue }
                ns.replaceCharacters(in: t.range, with: chipped[id].map(ids.contains) == true ? "" : label)
            }
            return (ns as String).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        fileCardsOnly = own && !files.isEmpty && media + audio.count + unknown == 0 && residue(without: files).isEmpty
        audioOnly = own && !audio.isEmpty && media + files.count + unknown == 0 && residue(without: audio).isEmpty
    }

    /// `userMessageFileLabel` (TimelineUserMessageRow.logic.ts:7-12 at 4928).
    static func fileLabel(_ file: JSONValue) -> String {
        file["source"]?["_tag"]?.stringValue == "pasted-text" ? "Pasted text" : file["name"]?.stringValue ?? "Attachment"
    }
}
