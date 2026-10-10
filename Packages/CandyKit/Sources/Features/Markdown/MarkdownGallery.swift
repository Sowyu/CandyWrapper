import AppKit
import DesignSystem

/// The Markdown section of the component gallery: every element MarkdownView draws.
@MainActor
public enum MarkdownGallery {
    public static let sample = """
    # Heading one
    Plain text with **bold**, *italic*, ~~struck~~, `inline code` and a [link](#setup).

    ## Heading two
    ### Heading three

    - A bullet with `code`
      - Nested
        - Deeper
    1. Ordered
    2. List
    - [ ] Open task
    - [x] Done task

    > A blockquote stays muted.

    > [!NOTE]
    > Useful information.

    > [!WARNING]
    > Needs attention.

    | Name | State | CPU |
    |---|:---:|---:|
    | t3 serve | running | 0.4% |
    | claude | waiting | 2.1% |

    ```swift
    @MainActor final class Box: NSView {
        let name = "box" // a comment
        func draw(_ rect: NSRect) -> Bool { return true }
    }
    ```

    ```bash
    swift test --filter Markdown && echo "done: $HOME"
    ```

    ---

    ![Image placeholder](https://example.com/a.png)
    """

    /// Width of a gallery column's content (1100 / 2 - 32).
    static let width: CGFloat = 518

    public static var section: ComponentGallery.Section {
        let probe = MarkdownView(frame: .zero)
        probe.setMarkdown(sample)
        return ComponentGallery.Section(title: "Markdown", height: probe.height(forWidth: width)) {
            let view = MarkdownView(frame: .zero)
            view.setMarkdown(sample)
            return view
        }
    }
}
