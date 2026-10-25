import AppKit
import Foundation
import Testing
@testable import Features

/// Any process of this macOS user can read the general pasteboard, so no Space code may write to it on its own.
/// Copy in the page editor writes only to the pasteboard AppKit hands it, after the user presses ⌘C.
struct SpacePasteboardTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized

    static var spaceSources: [URL] {
        let fm = FileManager.default
        let app = repo.appendingPathComponent("App/Sources")
        var files = ((try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Space") && $0.pathExtension == "swift" }
        let kit = repo.appendingPathComponent("Packages/CandyKit/Sources")
        for folder in ["Features/Space", "SpaceCrypto", "SpaceEngine", "SpaceFields", "SpaceLocal", "SpaceModel", "SpacePlanning"] {
            let walk = fm.enumerator(at: kit.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            files += (walk?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        }
        return files
    }

    @Test func noSpacePathWritesTheGeneralPasteboard() throws {
        let sources = Self.spaceSources
        #expect(sources.contains { $0.lastPathComponent == "SpaceController.swift" })
        #expect(sources.count > 20)
        // A write through NSPasteboard.general itself, or through a variable holding it.
        let write = try NSRegularExpression(pattern: #"NSPasteboard\.general\s*\.\s*(set|write|clear|prepare|declare|add)|=\s*NSPasteboard\.general\b"#)
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = write.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            #expect(hits == 0, "\(file.lastPathComponent) writes NSPasteboard.general")
        }
    }

    @MainActor @Test func recoveryKeyCannotBeSelectedOrCopied() throws {
        let field = SpaceRecoveryKeyLabel.make("ABCD-EFGH")
        #expect(field.stringValue == "ABCD-EFGH")
        #expect(!field.isSelectable && !field.isEditable && field.refusesFirstResponder)
        let controller = try String(contentsOf: Self.repo.appendingPathComponent("App/Sources/SpaceController.swift"), encoding: .utf8)
        #expect(controller.contains("SpaceRecoveryKeyLabel.make(key)"), "the first-run sheet shows the key through the unselectable label")
    }
}
