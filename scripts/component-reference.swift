// Renders T3's own component markup with T3's compiled stylesheet in headless Chromium and
// captures one PNG per case, state and theme. These are the per-component references the
// fidelity tests compare against. Capture tool only; the user approved headless Chromium for this.
//
// Usage: swift scripts/component-reference.swift <spec.json>   (run through scripts/component-reference)
//
// spec.json: { "component": "button", "states": [...], "themes": ["light", "dark"],
//              "cases": [ { "name": "outline.sm", "html": "<button ...>", "wrapperStyle": "...", "stateTarget": "input" } ] }
// `stateTarget` (optional) is a selector inside the case element that receives the forced state and the
// `disabled` attribute, for wrappers styled with `:has()` (Input, Textarea, InputGroup).
// `prepare` (optional) is a JS expression run once per theme after load, awaited if it returns a
// promise, for markup that T3 builds at runtime (Shiki highlighting in the markdown spec).
// States: rest, hover, active (hover + active), focus-visible (focus + focus-visible), disabled
// (the `disabled` attribute). Pseudo classes are forced with CSS.forcePseudoState.
// Output: design/component-reference/<component>/<case>.<state>.<theme>.png at 2x, clipped to the
// element's rest rect padded by 8 CSS px, plus manifest.json with each case's CSS size.
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: component-reference.swift <spec.json>"); exit(2) }
let root = URL(fileURLWithPath: args[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let component = spec["component"] as! String
let states = spec["states"] as? [String] ?? ["rest"]
let themes = spec["themes"] as? [String] ?? ["light", "dark"]
let cases = spec["cases"] as! [[String: Any]]
let outDir = root.appendingPathComponent("design/component-reference/\(component)")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let pad = 8.0, scale = 2.0

// MARK: - Pages

let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candywrapper-component-ref-\(getpid())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let cssURL = root.appendingPathComponent("design/t3-source/main.css").absoluteString
// The plain --background replaces the app chrome color and grain, matching the native test canvas.
// Transitions are off so forced states are final on the next frame.
let harnessCSS = """
body { background: var(--background) !important; background-image: none !important; height: auto !important; overflow: visible !important; }
*, *::before, *::after { transition: none !important; animation: none !important; }
.case { padding: 24px; }
"""
func page(theme: String) throws -> URL {
    let body = cases.map { c in
        "<div class=\"case\"><div style=\"\((c["wrapperStyle"] as? String) ?? "display:inline-block")\">\(c["html"] as! String)</div></div>"
    }.joined(separator: "\n")
    let html = """
    <!doctype html><html lang="en" class="\(theme == "dark" ? "dark" : "")"><head><meta charset="utf-8">
    <link rel="stylesheet" href="\(cssURL)"><style>\(harnessCSS)</style></head><body>\(body)</body></html>
    """
    let url = work.appendingPathComponent("\(theme).html")
    try html.write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: - Browser

let toolDir = NSHomeDirectory() + "/.t3/tools/chrome-headless-shell/mac-arm64"
let chrome = (try? FileManager.default.contentsOfDirectory(atPath: toolDir))?.sorted().last.map { "\(toolDir)/\($0)/chrome-headless-shell" }
guard let chrome, FileManager.default.isExecutableFile(atPath: chrome) else { print("chrome-headless-shell not found under ~/.t3/tools"); exit(1) }
let port = 9334 + Int(getpid() % 500) // per process, so parallel captures never share a DevTools port
let proc = Process()
proc.executableURL = URL(fileURLWithPath: chrome)
proc.arguments = ["--remote-debugging-port=\(port)", "--user-data-dir=\(work.appendingPathComponent("profile").path)",
                  "--hide-scrollbars", "--force-device-scale-factor=\(scale)", "--force-color-profile=srgb",
                  "--disable-gpu", "--no-first-run", "--font-render-hinting=none", "--allow-file-access-from-files", "about:blank"]
proc.standardOutput = FileHandle.nullDevice
proc.standardError = FileHandle.nullDevice
try proc.run()
print("chromium pid \(proc.processIdentifier)")
defer { proc.terminate() }

func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

var wsURL: URL?
for _ in 0..<50 {
    if let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/json/list")!),
       let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
       let p = list.first(where: { ($0["type"] as? String) == "page" }),
       let s = p["webSocketDebuggerUrl"] as? String { wsURL = URL(string: s); break }
    await sleep(0.2)
}
guard let wsURL else { print("DevTools endpoint did not come up"); exit(1) }
let ws = URLSession.shared.webSocketTask(with: wsURL)
ws.maximumMessageSize = 256 * 1024 * 1024
ws.resume()

actor CDP {
    var nextId = 1
    var waiting: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    func register(_ c: CheckedContinuation<[String: Any], Never>) -> Int { let id = nextId; nextId += 1; waiting[id] = c; return id }
    func resolve(_ id: Int, _ msg: [String: Any]) { waiting.removeValue(forKey: id)?.resume(returning: msg) }
}
let cdp = CDP()
Task {
    while true {
        guard case .string(let text) = try await ws.receive(),
              let msg = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
        if let id = msg["id"] as? Int { await cdp.resolve(id, msg) }
    }
}

@discardableResult
func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
    let msg = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
        Task {
            let id = await cdp.register(c)
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            try await ws.send(.string(String(decoding: data, as: UTF8.self)))
        }
    }
    if let err = msg["error"] { print("CDP \(method) error: \(err)") }
    return (msg["result"] as? [String: Any]) ?? [:]
}

func evaluate(_ expr: String) async throws -> Any? {
    let r = try await send("Runtime.evaluate", ["expression": expr, "awaitPromise": true, "returnByValue": true])
    return (r["result"] as? [String: Any])?["value"]
}

/// Waits two frames so style and paint catch up with a state change.
func settle() async throws { _ = try await evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))") }

// MARK: - Capture

try await send("Page.enable")
try await send("DOM.enable")
try await send("CSS.enable")
try await send("Emulation.setDeviceMetricsOverride", ["width": 900, "height": 900, "deviceScaleFactor": scale, "mobile": false])
var manifest: [String: [String: Double]] = [:]
for theme in themes {
    try await send("Page.navigate", ["url": try page(theme: theme).absoluteString])
    await sleep(1)
    _ = try await evaluate("document.fonts.ready.then(() => true)")
    if let prepare = spec["prepare"] as? String {
        // The first import of T3's client chunks in a fresh profile can navigate the page, which
        // drops the evaluation. Reload once and run it again.
        var result = try await evaluate(prepare)
        if result == nil {
            try await send("Page.navigate", ["url": try page(theme: theme).absoluteString])
            await sleep(1)
            result = try await evaluate(prepare)
        }
        print("prepare (\(theme)): \(result ?? "no result")")
    }
    let docHeight = try await evaluate("document.documentElement.scrollHeight") as? Double ?? 900
    try await send("Emulation.setDeviceMetricsOverride", ["width": 900, "height": Int(docHeight), "deviceScaleFactor": scale, "mobile": false])
    try await settle()
    let doc = try await send("DOM.getDocument", ["depth": 0])
    let rootId = (doc["root"] as! [String: Any])["nodeId"] as! Int
    let nodeIds = (try await send("DOM.querySelectorAll", ["nodeId": rootId, "selector": ".case > div > :first-child"]))["nodeIds"] as! [Int]
    precondition(nodeIds.count == cases.count, "found \(nodeIds.count) elements for \(cases.count) cases")

    for (i, c) in cases.enumerated() {
        let name = c["name"] as! String
        let rect = try await evaluate("(() => { const r = document.querySelectorAll('.case > div > :first-child')[\(i)].getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; })()") as! [Double]
        manifest[name] = ["width": rect[2], "height": rect[3]]
        let clip: [String: Any] = ["x": rect[0] - pad, "y": rect[1] - pad, "width": rect[2] + 2 * pad, "height": rect[3] + 2 * pad, "scale": 1]
        var target = nodeIds[i]
        if let selector = c["stateTarget"] as? String {
            let found = try await send("DOM.querySelector", ["nodeId": nodeIds[i], "selector": selector])
            guard let id = found["nodeId"] as? Int, id != 0 else { print("\(name): no element for stateTarget \(selector)"); exit(1) }
            target = id
        }
        for state in states {
            let forced: [String] = switch state {
            case "hover": ["hover"]
            case "active": ["hover", "active"]
            case "focus-visible": ["focus", "focus-visible"]
            default: []
            }
            if state == "disabled" { try await send("DOM.setAttributeValue", ["nodeId": target, "name": "disabled", "value": ""]) }
            try await send("CSS.forcePseudoState", ["nodeId": target, "forcedPseudoClasses": forced])
            try await settle()
            let shot = try await send("Page.captureScreenshot", ["format": "png", "clip": clip, "captureBeyondViewport": false])
            guard let b64 = shot["data"] as? String, let png = Data(base64Encoded: b64) else { print("no screenshot for \(name).\(state)"); continue }
            try png.write(to: outDir.appendingPathComponent("\(name).\(state).\(theme).png"))
            try await send("CSS.forcePseudoState", ["nodeId": target, "forcedPseudoClasses": [String]()])
            if state == "disabled" { try await send("DOM.removeAttribute", ["nodeId": target, "name": "disabled"]) }
        }
    }
    print("\(theme): \(cases.count * states.count) images")
}
let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try manifestData.write(to: outDir.appendingPathComponent("manifest.json"))
ws.cancel(with: .normalClosure, reason: nil)
