// Prints the main window id of an app, for screencapture -l. Usage: winid [pid] [--all], pid defaults to CW_UI_PID.
// --all lists every window: id, layer, x y w h in global points, on screen or not, title.
let args = CommandLine.arguments.dropFirst()
guard let pid = pidArgument(args.first(where: { $0 != "--all" })) else { print("usage: winid <pid> [--all]"); exit(2) }
if args.contains("--all") {
    for w in appWindows(pid) {
        let b = w.bounds
        print(w.id, w.layer, Int(b.minX), Int(b.minY), Int(b.width), Int(b.height), w.onscreen ? "onscreen" : "offscreen", w.name)
    }
} else if let w = mainWindow(pid) {
    print(w.id)
} else {
    FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8)); exit(1)
}
