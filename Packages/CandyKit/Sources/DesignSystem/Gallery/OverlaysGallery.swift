import AppKit

/// Gallery sections for the overlays batch. Each batch owns its own file so agents never edit the same list.
/// Modals and toasts show statically open inside fixed-size frames, with no motion and persistent toasts.
@MainActor
enum OverlaysGallery {
    static let paragraph = "T3 Code runs coding agents against your repositories. Each thread keeps its own worktree, "
        + "so two agents can edit the same project at once, and every diff stays reviewable before you merge it."

    static var sections: [ComponentGallery.Section] {
        [
            .init(title: "TextBlock: wrapping at 160, 240 and 340pt, centered, clamped to 2 lines", height: 220) {
                Fixed { frame in
                    var x: CGFloat = 0
                    for w in [160, 240, 340] as [CGFloat] {
                        let t = TextBlockView(paragraph, font: DSFont.ui(14), lineHeight: 20)
                        t.frame = NSRect(x: x, y: 0, width: w, height: t.height(forWidth: w))
                        frame.addSubview(t)
                        x += w + 16
                    }
                    let clamp = TextBlockView(paragraph, font: DSFont.ui(13), lineHeight: 18, color: Themed.color(\.contrastMutedForeground))
                    clamp.maxLines = 2
                    clamp.alignment = .center
                    clamp.frame = NSRect(x: 0, y: 176, width: 300, height: clamp.height(forWidth: 300))
                    frame.addSubview(clamp)
                }
            },
            .init(title: "Dialog: header, panel, default footer, close button (backdrop tint only)", height: 340) {
                modal(DialogView(title: "Rename thread", message: "Pick a name you will recognise in the sidebar."), panel: true)
            },
            .init(title: "AlertDialog: bare footer, no close button", height: 220) {
                let d = DialogView(kind: .alertDialog, title: "Delete this thread?",
                                   message: "The thread and its history are removed from this device and the server.")
                d.footerVariant = .bare
                d.footerButtons = [ButtonView("Cancel", variant: .outline), ButtonView("Delete", variant: .destructive)]
                return Fixed { $0.addSubview(ModalHost(panel: d)) }
            },
            .init(title: "Sheet: right side and inset", height: 300) {
                Fixed { frame in
                    for (i, inset) in [false, true].enumerated() {
                        let s = DialogView(kind: .sheet(.right), title: "Thread settings", message: "Model, runtime and worktree.")
                        s.isInset = inset
                        let host = ModalHost(panel: s)
                        host.frame = NSRect(x: CGFloat(i) * 264, y: 0, width: 256, height: 300)
                        frame.addSubview(host)
                    }
                }
            },
            .init(title: "Toasts: collapsed stack of three, then the same stack expanded", height: 330) {
                Fixed { frame in
                    for (i, expanded) in [false, true].enumerated() {
                        let viewport = ToastViewport(frame: NSRect(x: 40, y: CGFloat(i) * 110 + 8, width: 360, height: 220))
                        frame.addSubview(viewport)
                        viewport.show(ToastView(title: "Thread archived", message: "Find it under Archived.", kind: .info, actionTitle: "Undo"), timeout: 0)
                        viewport.show(ToastView(title: "Could not reach the server", kind: .error), timeout: 0)
                        viewport.show(ToastView(title: "Changes pushed to origin/main", kind: .success), timeout: 0)
                        if expanded { viewport.setHovered(true) }
                    }
                }
            },
        ]
    }

    static func modal(_ d: DialogView, panel: Bool) -> NSView {
        if panel {
            d.panelContent = [TextBlockView("Thread names show in the sidebar, the command palette and notifications.",
                                            font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.contrastPopoverForeground))]
        }
        d.footerButtons = [ButtonView("Cancel", variant: .outline), ButtonView("Save")]
        return Fixed { $0.addSubview(ModalHost(panel: d)) }
    }

    /// A fixed-size frame: `build` adds children once; a lone ModalHost child fills it.
    final class Fixed: DSView {
        init(_ build: (Fixed) -> Void) {
            super.init(frame: .zero)
            layer?.masksToBounds = true
            build(self)
        }

        override func layout() {
            super.layout()
            if subviews.count == 1, let host = subviews.first as? ModalHost { host.frame = bounds }
        }
    }
}
