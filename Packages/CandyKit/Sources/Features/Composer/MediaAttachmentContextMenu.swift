import AppKit
import DesignSystem
import T3Store

/// MediaActions.tsx:150-174. Decode only when a media action is requested.
@MainActor
public enum MediaAttachmentContextMenu {
    public static func show(name: String, load: @escaping AsyncImageView.Loader, event: NSEvent, view: NSView) {
        let menu = NativeItemContextMenu.make([ThreadMenuItem("save", "Save image"), ThreadMenuItem("copy", "Copy image")]) { [weak view] action in
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
