// A bare TextKit 2 NSTextView in a plain window: the floor of the keypress-to-glyph pipeline on this Mac.
// Build: swiftc -O scripts/perf/floor.swift -o /tmp/cw-perf/bin/floor. Usage: floor <x> <y> (the window's top-left
// corner in global points). Its first text line starts 28pt below that, so `frames key <x+2> <y+28> 400 30 30` watches it.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let args = CommandLine.arguments
let x = args.count > 1 ? Double(args[1]) ?? 400 : 400, y = args.count > 2 ? Double(args[2]) ?? 300 : 300
let screen = NSScreen.main!.frame
let size = NSSize(width: 760, height: 160)
let window = NSWindow(contentRect: NSRect(x: x, y: screen.height - y - size.height, width: size.width, height: size.height),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
let text = NSTextView(usingTextLayoutManager: true)
text.frame = NSRect(origin: .zero, size: size)
text.font = .systemFont(ofSize: 14)
text.backgroundColor = NSColor(white: 0.07, alpha: 1)
text.textColor = .white
text.insertionPointColor = .white
text.isRichText = false
text.isAutomaticSpellingCorrectionEnabled = false
text.isContinuousSpellCheckingEnabled = false
window.contentView = text
window.title = "floor"
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(text)
app.activate(ignoringOtherApps: true)
app.run()
