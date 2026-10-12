import AppKit
import DesignSystem
import T3Store

/// MediaActions.tsx:150-174. Decode only when a media action is requested. With a `reference` the menu
/// first offers the original's path or URL, and "Open in file viewer" for a workspace file.
@MainActor
public enum MediaAttachmentContextMenu {
    public static func show(name: String, load: @escaping AsyncImageView.Loader, event: NSEvent, view: NSView,
                            reference: MediaReference? = nil, openFile: (() -> Void)? = nil) {
        var items: [ThreadMenuItem] = []
        switch reference {
        case .file(_, let relative)?:
            items.append(ThreadMenuItem("copy-full-path", "Copy full path"))
            if relative != nil { items.append(ThreadMenuItem("copy-relative-path", "Copy relative path")) }
        case .url?: items.append(ThreadMenuItem("copy-url", "Copy URL"))
        case nil: break
        }
        if openFile != nil { items.append(ThreadMenuItem("open-file", "Open in file viewer")) }
        items += [ThreadMenuItem("save", "Save image"), ThreadMenuItem("copy", "Copy image")]
        let menu = NativeItemContextMenu.make(items) { [weak view] action in
            let text: String? = switch (action, reference) {
            case ("copy-full-path", .file(let path, _)?): path
            case ("copy-relative-path", .file(_, let relative?)?): relative
            case ("copy-url", .url(let url)?): url
            default: nil
            }
            if let text {
                NSPasteboard.general.clearContents()
                let copied = NSPasteboard.general.setString(text, forType: .string)
                if let view { AnchoredCopyToast.show(from: view, success: copied) }
                return
            }
            if action == "open-file" { openFile?(); return }
            Task { @MainActor in
                guard let image = await load(16_384) else { return }
                let rep = NSBitmapImageRep(cgImage: image)
                if action == "copy" {
                    NSPasteboard.general.clearContents()
                    let success = NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
                    if let view { AnchoredCopyToast.show(from: view, success: success) }
                } else {
                    guard let window = view?.window else { return }
                    let picker = NSSavePanel()
                    picker.nameFieldStringValue = (name as NSString).deletingPathExtension + ".png"
                    picker.beginSheetModal(for: window) { result in
                        guard result == .OK, let url = picker.url,
                              let data = rep.representation(using: .png, properties: [:]) else { return }
                        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
                    }
                }
            }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}
