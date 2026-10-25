import AppKit
import Foundation
import SpaceEngine
import SpaceModel
import Testing
@testable import Features

/// The title column's name and visibility, Files & media cells, page icons and SVG import (docs/space.md "Table",
/// "Page record" and section 7).
@MainActor
struct SpaceTableMediaTests {
    func make() throws -> (SpaceTableModel, SpaceReplicaStore, PageID) {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Subscriptions", now: 1)
        var record = store.pages[page]!
        record.fields = [
            "price": FieldDefinition(name: "Price", type: .number, order: try OrderKey("a1")),
            "media": FieldDefinition(name: "Files & media", type: .files, order: try OrderKey("a2")),
        ]
        record.view = .table
        var changes = [try RecordChange.page(page, record)]
        for (i, title) in ["Streamly", "Tunes"].enumerated() {
            changes.append(try RecordChange.page(PageID(), PageRecord(parent: page, order: try OrderKey("b\(i)"), title: title, created: 2)))
        }
        store.edit(changes)
        return (SpaceTableModel(store: store, page: page), store, page)
    }

    func column(_ model: SpaceTableModel, _ id: String) -> SpaceTableModel.Column { model.columns.first { $0.id == id }! }
    let logo = BlobReference(id: String(repeating: "a", count: 64), name: "logo.svg", mime: "image/png", size: 900, w: 1024, h: 1024)
    let receipt = BlobReference(id: String(repeating: "b", count: 64), name: "receipt.pdf", mime: "application/pdf", size: 52_000)

    @Test func titleColumnRenamesAndUndoes() throws {
        let (model, store, page) = try make()
        #expect(column(model, FieldID.title).name == "Title")
        model.renameField(FieldID.title, "Service")
        #expect(store.pages[page]?.titleName == "Service")
        #expect(column(model, FieldID.title).name == "Service")
        #expect(model.name(of: FieldID.title) == "Service")
        model.undo.undo()
        #expect(store.pages[page]?.titleName == nil)
        #expect(column(model, FieldID.title).name == "Title")
    }

    @Test func titleHidesInThisViewAndComesBack() throws {
        let (model, store, page) = try make()
        model.resize(FieldID.title, to: 320)
        model.setHidden(FieldID.title, true)
        #expect(store.pages[page]?.views.table?.titleHidden == true)
        #expect(model.columns.first?.id == "price")
        // Another settings write keeps the hidden title's width.
        model.resize("price", to: 140)
        model.setHidden(FieldID.title, false)
        #expect(model.columns.first?.id == FieldID.title)
        #expect(model.columns.first?.width == 320)
        #expect(store.pages[page]?.views.table?.titleHidden == false)
    }

    @Test func deletingAFieldUndoesWithItsValues() throws {
        let (model, store, page) = try make()
        model.setText(0, column(model, "price"), "12.99")
        model.deleteField("price")
        #expect(store.pages[page]?.fields["price"] == nil)
        #expect(!model.columns.contains { $0.id == "price" })
        model.undo.undo()
        #expect(model.columns.contains { $0.id == "price" })
        #expect(model.cell(0, column(model, "price")) == .number("12.99"))
    }

    @Test func filesAddWithoutDuplicatesAndRemove() throws {
        let (model, _, _) = try make()
        let media = column(model, "media")
        #expect(model.cell(0, media) == .empty)
        model.addFiles(0, media, [logo, receipt])
        model.addFiles(0, media, [logo])
        #expect(model.files(0, media) == [logo, receipt])
        #expect(model.cell(0, media) == .files([logo, receipt]))
        model.removeFile(0, media, at: 0)
        #expect(model.files(0, media) == [receipt])
        model.removeFile(0, media, at: 0)
        #expect(model.rows[0].page.props["media"] == nil)
        model.undo.undo()
        #expect(model.files(0, media) == [receipt])
    }

    @Test func rowIconsSetClearAndUndo() throws {
        let (model, store, _) = try make()
        let id = model.rows[0].id
        model.setIcon(0, .emoji("🎬"))
        #expect(store.pages[id]?.icon == "🎬")
        model.setIcon(0, .image(logo))
        #expect(store.pages[id]?.iconImage == logo)
        #expect(store.pages[id]?.icon == nil)
        #expect(SpacePageIcon.choice(store.pages[id]!) == .image(logo))
        model.setIcon(0, .none)
        #expect(!SpacePageIcon.has(store.pages[id]!))
        model.undo.undo()
        #expect(SpacePageIcon.choice(store.pages[id]!) == .image(logo))
    }

    @Test func filesCellHitsThumbnails() {
        let refs = [logo, receipt, logo]
        #expect(SpaceTableCellDrawing.visibleThumbs(3, width: 200) == 3)
        #expect(SpaceTableCellDrawing.thumbIndex(refs, at: 12, width: 200) == 0)
        #expect(SpaceTableCellDrawing.thumbIndex(refs, at: 10 + 26 + 3, width: 200) == 1)
        #expect(SpaceTableCellDrawing.thumbIndex(refs, at: 10 + 22 + 1, width: 200) == nil)
        #expect(SpaceTableCellDrawing.visibleThumbs(10, width: 100) < 10)
    }

    @Test func deleteForeverKeepsBlobsOtherPagesUse() {
        let id = String(repeating: "c", count: 64)
        let ref: SpaceModel.JSONValue = .object(["id": .string(id), "name": .string("a.png"), "mime": .string("image/png"), "size": .number(1)])
        let page: [String: SpaceModel.JSONValue] = ["iconImage": ref, "props": .object(["media": .array([ref]), "tags": .array([.string("x")])])]
        #expect(PersistentSpacePageStore.blobIDs(inPage: page) == [id])
        #expect(PersistentSpacePageStore.blobIDs(inPage: ["title": .string("x")]).isEmpty)
    }

    @Test func uploadsLandOnARowThatWasFilteredAway() throws {
        let (model, _, _) = try make()
        let id = model.rows[1].id
        model.addFilter(Filter(field: FieldID.title, op: .is, value: .string("Streamly")))
        #expect(!model.rows.contains { $0.id == id })
        model.addFiles(to: id, field: "media", [logo])
        model.setIcon(of: id, .image(logo))
        model.removeFilter(0)
        let i = try #require(model.rows.firstIndex { $0.id == id })
        #expect(model.files(i, column(model, "media")) == [logo])
        #expect(model.rows[i].page.iconImage == logo)
    }

    @Test func filesListScrollsPastFiveFiles() throws {
        let (model, _, _) = try make()
        let refs = (0..<7).map { BlobReference(id: String(repeating: "\($0)", count: 64), name: "f\($0).png", mime: "image/png", size: 10) }
        model.addFiles(0, column(model, "media"), refs)
        let doc = SpaceTableDocument(model: model)
        let popover = SpaceFilesPopover(doc: doc, row: model.rows[0].id, column: "media")
        popover.setFrameSize(popover.intrinsicContentSize)
        popover.layoutSubtreeIfNeeded()
        #expect(popover.scroll.frame.height == 5.5 * SpaceFilesPopover.rowHeight)
        #expect(popover.scroll.documentView?.frame.height == 7 * SpaceFilesPopover.rowHeight)
    }

    @Test func deleteToastClosesOnTheNextChange() throws {
        let (model, _, page) = try make()
        let table = SpaceTableView(store: model.store, page: page)
        table.doc.deleteField("price")
        #expect(table.deleteToast != nil)
        table.model.setText(0, table.model.columns[0], "Renamed")
        #expect(table.deleteToast == nil)
    }

    @Test func emojiSearchMatchesWordPrefixes() {
        #expect(SpaceEmoji.all.count > 900)
        #expect(SpaceEmoji.all.first?.emoji == "😀")
        #expect(SpaceEmoji.search("red app").map(\.emoji).contains("🍎"))
        #expect(SpaceEmoji.search("money").contains { $0.emoji == "💰" })
        #expect(SpaceEmoji.search("zzzz").isEmpty)
        #expect(SpaceEmoji.search("").count == SpaceEmoji.all.count)
    }
}

/// SVGs never reach the blob store as SVG: they're sanitized, then drawn into a PNG.
struct SpaceImageImportTests {
    let hostile = """
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 64 32" onload="alert(1)">\
    <?xml-stylesheet href="http://example.com/x.css"?><script>fetch('http://example.com')</script>\
    <style>@import url(http://example.com/a.css);</style><rect width="64" height="32" fill="#7c3aed"/>\
    <image xlink:href="http://example.com/t.png" width="10" height="10"/><a href="javascript:alert(1)"><circle r="4" fill="url(http://example.com/#g)"/></a>\
    <use href="#r"/><foreignObject><div xmlns="http://www.w3.org/1999/xhtml">x</div></foreignObject><animate attributeName="href" to="javascript:alert(1)"/></svg>
    """

    @Test func sanitizerDropsScriptsHandlersAndExternalResources() throws {
        let clean = try #require(SpaceImageImport.sanitizeSVG(Data(hostile.utf8)))
        let text = String(decoding: clean, as: UTF8.self).lowercased()
        for banned in ["<script", "onload", "foreignobject", "@import", "example.com", "javascript:", "<animate", "xml-stylesheet"] {
            #expect(!text.contains(banned), "still has \(banned)")
        }
        #expect(text.contains("<rect"))
        #expect(text.contains("href=\"#r\""))
    }

    @Test func cssEscapesAndOddURLsAreDropped() throws {
        let svg = #"""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><defs><linearGradient id="g"/></defs>\
        <style>rect{fill:\\75rl(http://example.com/a)}</style><rect width="10" height="10" style="fill:\\75rl(http://example.com/b)"/>\
        <circle r="3" fill="url('#g')"/><circle r="2" fill="url( #g )"/><circle r="1" fill="URL(&quot;http://example.com/c&quot;)"/></svg>
        """#
        let clean = try #require(SpaceImageImport.sanitizeSVG(Data(svg.utf8)))
        let text = String(decoding: clean, as: UTF8.self).lowercased()
        #expect(!text.contains("example.com"))
        #expect(!text.contains("<style"))
        #expect(text.contains("url('#g')"))
        #expect(text.contains("url( #g )"))
    }

    @Test func svgRootsAreFoundWhateverTheName() throws {
        let comment = "<!-- " + String(repeating: "x", count: 900) + " -->"
        let svg = #"<?xml version="1.0"?>"# + comment + #"<svg:svg xmlns:svg="http://www.w3.org/2000/svg" viewBox="0 0 2 1"><svg:rect width="2" height="1"/></svg:svg>"#
        #expect(SpaceImageImport.looksLikeSVG(Data(svg.utf8)))
        #expect(SpaceImageImport.looksLikeSVG(svg.data(using: .utf16)!))
        let p = try SpaceImageImport.prepare(Data(svg.utf8), name: "notes.txt")
        #expect(p.mime == "image/png")
        #expect(!SpaceImageImport.looksLikeSVG(Data("<html><body><svg/></body></html>".utf8)))
        #expect(try SpaceImageImport.prepare(Data("<html><svg/></html>".utf8), name: "page.html").mime == "text/html")
    }

    @Test func documentTypeDeclarationsAreRefused() {
        let xxe = #"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg xmlns="http://www.w3.org/2000/svg">&x;</svg>"#
        #expect(SpaceImageImport.sanitizeSVG(Data(xxe.utf8)) == nil)
        #expect(SpaceImageImport.sanitizeSVG(Data("<html><svg/></html>".utf8)) == nil)
    }

    @Test func svgImportsAsAPNGAtItsAspectRatio() throws {
        let p = try SpaceImageImport.prepare(Data(hostile.utf8), name: "logo.svg")
        #expect(p.mime == "image/png")
        #expect(p.name == "logo.svg")
        #expect(p.w == 1024 && p.h == 512)
        #expect(p.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let rep = try #require(NSBitmapImageRep(data: p.data))
        #expect(rep.pixelsWide == 1024)
    }

    @Test func otherFilesPassThrough() throws {
        let png = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))
        let image = try SpaceImageImport.prepare(png, name: "shot.png")
        #expect(image.mime == "image/png" && image.w == 3 && image.h == 2 && image.data == png)
        let pdf = try SpaceImageImport.prepare(Data("%PDF-1.4".utf8), name: "receipt.pdf")
        #expect(pdf.mime == "application/pdf" && pdf.w == nil)
    }
}
