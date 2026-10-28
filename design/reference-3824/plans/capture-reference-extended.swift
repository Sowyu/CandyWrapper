// Captures reference screenshots of the official T3 web client at exact device
// pixels by driving chrome-headless-shell over the DevTools protocol.
// Capture tool only. The user approved headless Chromium for this; it never ships.
//
// Usage: capture-reference-extended <plan.json> <out-dir> [pairing-url]
//
// plan.json:
// { "base": "http://127.0.0.1:47403", "width": 1100, "height": 780, "scale": 2,
//   "themes": ["dark", "light"],
//   "states": [ { "name": "new-thread", "path": "/", "actions": [ {"click": "text=Dismiss"}, {"wait": 400} ] } ] }
// Actions: {"path": "/settings"}, {"click": "<css>" | "text=<label>"}, {"hover": "<css>" | "text=..."},
//          {"key": "Escape" | "k", "meta": true}, {"type": "hello"}, {"js": "<expression>"}, {"wait": ms}
// Output: <out-dir>/<name>.<theme>.png at width*scale x height*scale.
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: capture-reference.swift <plan.json> <out-dir> [pairing-url]"); exit(2) }
let plan = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let pairingURL = args.count >= 4 ? args[3] : nil

let base = plan["base"] as? String ?? "http://127.0.0.1:47403"
let width = plan["width"] as? Int ?? 1100, height = plan["height"] as? Int ?? 780
let scale = plan["scale"] as? Double ?? 2
let themes = plan["themes"] as? [String] ?? ["dark", "light"]
let states = plan["states"] as? [[String: Any]] ?? []

let chrome = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.t3/tools/chrome-headless-shell/mac-arm64"))?
    .sorted().last.map { NSHomeDirectory() + "/.t3/tools/chrome-headless-shell/mac-arm64/\($0)/chrome-headless-shell" }
guard let chrome, FileManager.default.isExecutableFile(atPath: chrome) else { print("chrome-headless-shell not found under ~/.t3/tools"); exit(1) }

// Persistent profile keeps the paired session cookie between runs.
let profile = ProcessInfo.processInfo.environment["CAPTURE_PROFILE"]
    ?? NSHomeDirectory() + "/CandyWrapper-research/sandbox-3824-ref/chrome-3824-profile"
let port = Int(ProcessInfo.processInfo.environment["CAPTURE_PORT"] ?? "9450")!
let proc = Process()
proc.executableURL = URL(fileURLWithPath: chrome)
proc.arguments = ["--remote-debugging-port=\(port)", "--user-data-dir=\(profile)", "--hide-scrollbars",
                  "--window-size=\(width),\(height)", "--force-device-scale-factor=\(scale)",
                  "--disable-gpu", "--no-first-run", "--font-render-hinting=none", "about:blank"]
proc.standardOutput = FileHandle.nullDevice
proc.standardError = FileHandle.nullDevice
try proc.run()
defer { proc.terminate() }

func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

// Find the page target.
var wsURL: URL?
for _ in 0..<50 {
    if let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/json/list")!),
       let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
       let page = list.first(where: { ($0["type"] as? String) == "page" }),
       let s = page["webSocketDebuggerUrl"] as? String { wsURL = URL(string: s); break }
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
    if let error = r["exceptionDetails"] { print("JS error:", error) }; return (r["result"] as? [String: Any])?["value"]
}

// Resolves "text=Label" or a CSS selector to the element's centre point.
func center(_ target: String) async throws -> (Double, Double)? {
    let finder: String
    if target.hasPrefix("text=") {
        let label = String(target.dropFirst(5)).replacingOccurrences(of: "'", with: "\\'")
        finder = "[...document.querySelectorAll('button,a,[role=button],[role=menuitem],[role=option],[role=tab],li,span,div')].find(e => e.offsetParent !== null && (e.getAttribute('aria-label') === '\(label)' || e.textContent.trim() === '\(label)'))"
    } else {
        finder = "document.querySelector('\(target.replacingOccurrences(of: "'", with: "\\'"))')"
    }
    let v = try await evaluate("(() => { const e = \(finder); if (!e) return null; const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()")
    guard let p = v as? [Double], p.count == 2 else { return nil }
    return (p[0], p[1])
}

func mouse(_ type: String, _ x: Double, _ y: Double) async throws {
    try await send("Input.dispatchMouseEvent", ["type": type, "x": x, "y": y, "button": type == "mouseMoved" ? "none" : "left", "clickCount": 1])
}

func run(_ action: [String: Any]) async throws {
    if let path = action["path"] as? String {
        try await send("Page.navigate", ["url": base + path]); await sleep(1.5)
    } else if let t = action["click"] as? String {
        guard let (x, y) = try await center(t) else { print("  click target not found: \(t)"); return }
        try await mouse("mouseMoved", x, y); try await mouse("mousePressed", x, y); try await mouse("mouseReleased", x, y)
        await sleep(0.35)
    } else if let t = action["hover"] as? String {
        guard let (x, y) = try await center(t) else { print("  hover target not found: \(t)"); return }
        try await mouse("mouseMoved", x, y); await sleep(0.35)
    } else if let key = action["key"] as? String {
        let mods = (action["meta"] as? Bool == true ? 4 : 0) | (action["shift"] as? Bool == true ? 8 : 0) | (action["alt"] as? Bool == true ? 1 : 0) | (action["ctrl"] as? Bool == true ? 2 : 0)
        let vk: [String: Int] = ["Escape": 27, "Enter": 13, "Tab": 9, "ArrowDown": 40, "ArrowUp": 38, "Backspace": 8, ",": 188, "/": 191]
        for type in ["keyDown", "keyUp"] {
            try await send("Input.dispatchKeyEvent", ["type": type, "key": key, "code": key.count == 1 ? "Key\(key.uppercased())" : key,
                                                      "modifiers": mods, "windowsVirtualKeyCode": vk[key] ?? Int(key.uppercased().unicodeScalars.first!.value)] .merging(type == "keyDown" && key == "Enter" ? ["text": "\r"] : [:]) { a, _ in a })
        }
        await sleep(0.35)
    } else if let text = action["type"] as? String {
        try await send("Input.insertText", ["text": text]); await sleep(0.2)
    } else if let js = action["js"] as? String {
        let r = try await evaluate(js); if action["log"] as? Bool == true { print("JS:", r ?? "nil") }; await sleep(0.2)
    } else if let file = action["dump"] as? String {
        let value = try await evaluate("document.body.innerText + '\\n---ELEMENTS---\\n' + [...document.querySelectorAll('button,a,input,[contenteditable],[role=option]')].filter(e=>e.getBoundingClientRect().width).map(e=>e.outerHTML).join('\\n')"); try String(describing: value ?? "").write(toFile: file, atomically: true, encoding: .utf8)
    } else if let ms = (action["wait"] as? Double) ?? (action["wait"] as? Int).map(Double.init) {
        await sleep(ms / 1000)
    }
}

try await send("Page.enable")
try await send("Emulation.setDeviceMetricsOverride", ["width": width, "height": height, "deviceScaleFactor": scale, "mobile": false])
if let pairingURL {
    try await send("Page.navigate", ["url": pairingURL]); await sleep(3)
}

for theme in themes {
    try await send("Emulation.setEmulatedMedia", ["features": [["name": "prefers-color-scheme", "value": theme], ["name": "prefers-reduced-motion", "value": "reduce"]]])
    for state in states {
        let name = state["name"] as! String
        let captureTheme = state["theme"] as? String ?? theme
        try await send("Emulation.setEmulatedMedia", ["features": [["name": "prefers-color-scheme", "value": captureTheme], ["name": "prefers-reduced-motion", "value": "reduce"]]])
        if state["continue"] as? Bool != true { try await send("Page.navigate", ["url": base + (state["path"] as? String ?? "/")]); await sleep(2) }
        for action in (state["actions"] as? [[String: Any]]) ?? [] { try await run(action) }
        _ = try await evaluate("document.fonts.ready.then(() => true)")
        await sleep(0.4)
        try await mouse("mouseMoved", 1098, 1)
        await sleep(0.3)
        let shot = try await send("Page.captureScreenshot", ["format": "png", "fromSurface": true])
        guard let b64 = shot["data"] as? String, let png = Data(base64Encoded: b64) else { print("no screenshot for \(name)"); continue }
        let file = outDir.appendingPathComponent("\(name).\(captureTheme).png")
        try png.write(to: file)
        if let textDir = ProcessInfo.processInfo.environment["CAPTURE_TEXT_DIR"] {
            let body = try await evaluate("JSON.stringify({path:location.pathname,theme:document.documentElement.className,text:document.body.innerText})"); try String(describing: body ?? "").write(toFile: textDir + "/\(name).\(captureTheme).json", atomically: true, encoding: .utf8)
        }
        print("\(file.lastPathComponent)")
        fflush(stdout)
        for action in (state["afterActions"] as? [[String: Any]]) ?? [] { try await run(action) }
    }
}
ws.cancel(with: .normalClosure, reason: nil)
