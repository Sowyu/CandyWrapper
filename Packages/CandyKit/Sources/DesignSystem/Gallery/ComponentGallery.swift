import AppKit

/// The hidden component gallery: every component in every state, light and dark side by side.
/// Sections register here as components are built.
@MainActor
public enum ComponentGallery {
    /// One gallery section: a title and a builder for its content at a given width.
    public struct Section {
        public let title: String
        public let height: CGFloat
        public let make: @MainActor () -> NSView

        public init(title: String, height: CGFloat, make: @escaping @MainActor () -> NSView) {
            self.title = title
            self.height = height
            self.make = make
        }
    }

    public static var sections: [Section] {
        [ColorSwatches.section, TypeSamples.section, ButtonGallery.variantsSection, ButtonGallery.sizesSection]
            + FormsGallery.sections + TogglesGallery.sections + PopupsGallery.sections
            + OverlaysGallery.sections + LayoutGallery.sections + extraSections
    }

    /// Components append their sections here (kept in one place so the gallery stays complete).
    public static var extraSections: [Section] = []

    /// Light and dark columns, each rendering every section.
    public static func makeView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = GalleryDocument(sections: sections)
        scroll.documentView = document
        return scroll
    }

    /// Renders one section in one appearance, for exports and visual tests.
    public static func render(_ section: Section, width: CGFloat = 520, dark: Bool, scale: CGFloat = 2) -> NSBitmapImageRep {
        let host = GalleryColumn(sections: [section], dark: dark)
        return Snapshot.image(of: host, size: NSSize(width: width, height: host.contentHeight), scale: scale, dark: dark)
    }
}

/// Two columns side by side: light on the left, dark on the right.
final class GalleryDocument: DSView {
    private let columns: [GalleryColumn]

    init(sections: [ComponentGallery.Section]) {
        columns = [GalleryColumn(sections: sections, dark: false), GalleryColumn(sections: sections, dark: true)]
        super.init(frame: .zero)
        columns.forEach(addSubview)
        frame.size = NSSize(width: 1100, height: columns.map(\.contentHeight).max() ?? 0)
    }

    override func layout() {
        super.layout()
        let width = bounds.width / 2
        for (i, column) in columns.enumerated() {
            column.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: column.contentHeight)
        }
    }
}

/// One appearance: forces light or dark on its subtree, like T3's `.dark` class on `<html>`.
final class GalleryColumn: DSView {
    let contentHeight: CGFloat
    private let titleHeight: CGFloat = 28
    private let views: [(LabelView, NSView, CGFloat)]

    init(sections: [ComponentGallery.Section], dark: Bool) {
        var total: CGFloat = 16
        views = sections.map { section in
            let title = LabelView(section.title, font: DSFont.ui(12, weight: .semibold),
                                  color: ThemeColors.main.color(\.mutedForeground))
            total += 28 + section.height + 24
            return (title, section.make(), section.height)
        }
        contentHeight = total
        super.init(frame: .zero)
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for (title, content, _) in views {
            addSubview(title)
            addSubview(content)
        }
    }

    override func updateLayer() {
        layer?.backgroundColor = ThemeColors.main.color(\.background).cgColor(in: self)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 16
        for (title, content, height) in views {
            title.frame = NSRect(x: 16, y: y, width: bounds.width - 32, height: titleHeight)
            y += titleHeight
            content.frame = NSRect(x: 16, y: y, width: bounds.width - 32, height: height)
            y += height + 24
        }
    }
}
