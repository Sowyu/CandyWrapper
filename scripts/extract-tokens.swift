// Resolves every design token from the compiled T3 stylesheet with a real browser engine
// (headless Chromium over the DevTools protocol) and generates Swift plus a token sheet.
// Build-time tool only. Run through scripts/extract-tokens.
import Foundation

// MARK: - Arguments and paths

let root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
var dumpPath: String?
var loadPath: String?
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        if a == "--dump" { dumpPath = it.next() }
        else if a == "--load" { loadPath = it.next() }   // regenerate from a dump without a browser
    }
}
let cssURL = root.appendingPathComponent("design/t3-source/main.css")
let swiftOut = root.appendingPathComponent("Packages/CandyKit/Sources/DesignSystem/Tokens/Tokens.generated.swift")
let docOut = root.appendingPathComponent("docs/design-tokens.md")
let css = try String(contentsOf: cssURL, encoding: .utf8)
let t3Version = (try? String(contentsOf: root.appendingPathComponent("T3_VERSION"), encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

// MARK: - Token names

/// Every custom property declared in the stylesheet, minus Tailwind and lightningcss internals.
func collectNames(_ css: String) -> [String] {
    let re = try! NSRegularExpression(pattern: #"(?:^|[{;])(--[A-Za-z0-9_-]+):"#)
    var set = Set<String>()
    for m in re.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
        let n = String(css[Range(m.range(at: 1), in: css)!])
        if n.hasPrefix("--tw-") || n.contains("lightningcss") { continue }
        set.insert(n)
    }
    return set.sorted()
}

// MARK: - Page script

let pageScript = #"""
(async () => {
const NAMES = __NAMES__;
const root = document.documentElement;
const sidebar = document.createElement('div');
sidebar.setAttribute('data-app-sidebar', '');
document.body.appendChild(sidebar);
const round = (v) => Math.round(v * 10000) / 10000;

const canvases = {};
function canvasFor(space) {
  if (canvases[space]) return canvases[space];
  const c = document.createElement('canvas'); c.width = c.height = 1;
  let ctx = null, float = false;
  try {
    ctx = c.getContext('2d', { colorSpace: space, colorType: 'float16', willReadFrequently: true });
    float = ctx && ctx.getContextAttributes().colorType === 'float16';
  } catch (e) {}
  if (!float) ctx = c.getContext('2d', { colorSpace: space, willReadFrequently: true });
  return (canvases[space] = { ctx, float });
}
function pixel(space, color) {
  const k = canvasFor(space), ctx = k.ctx;
  ctx.clearRect(0, 0, 1, 1);
  ctx.fillStyle = '#000'; ctx.fillStyle = color;
  ctx.fillRect(0, 0, 1, 1);
  if (k.float) {
    try {
      const d = ctx.getImageData(0, 0, 1, 1, { pixelFormat: 'rgba-float32', colorSpace: space }).data;
      return [round(d[0]), round(d[1]), round(d[2]), round(d[3])];
    } catch (e) { k.float = false; }
  }
  const d = ctx.getImageData(0, 0, 1, 1).data;
  return [round(d[0] / 255), round(d[1] / 255), round(d[2] / 255), round(d[3] / 255)];
}
const colorOf = (css) => ({ srgb: pixel('srgb', css), p3: pixel('display-p3', css), css });

const EASE = { 'ease': [.25, .1, .25, 1], 'ease-in': [.42, 0, 1, 1], 'ease-out': [0, 0, .58, 1], 'ease-in-out': [.42, 0, .58, 1], 'linear': [0, 0, 1, 1] };

function splitTop(s, sep) {
  const out = []; let depth = 0, cur = '';
  for (const ch of s) {
    if (ch === '(') depth++; if (ch === ')') depth--;
    if (depth === 0 && (sep === ',' ? ch === ',' : /\s/.test(ch))) { if (cur.trim()) out.push(cur.trim()); cur = ''; }
    else cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

function parseShadow(probe, raw) {
  probe.style.boxShadow = raw;
  const comp = getComputedStyle(probe).boxShadow;
  return splitTop(comp, ',').map((layer) => {
    const parts = splitTop(layer, ' ');
    let inset = false, color = null; const nums = [];
    for (const p of parts) {
      if (p === 'inset') inset = true;
      else if (/^-?[\d.]+(px)?$/.test(p)) nums.push(parseFloat(p));
      else color = colorOf(p);
    }
    return { inset, x: nums[0] || 0, y: nums[1] || 0, blur: nums[2] || 0, spread: nums[3] || 0, color: color ? color.srgb : [0, 0, 0, 1] };
  });
}

function lenPx(probe, name, fs) {
  root.style.fontSize = fs;
  probe.style.marginLeft = `var(${name})`;
  const v = parseFloat(getComputedStyle(probe).marginLeft);
  root.style.fontSize = '';
  return v;
}

function resolve(host, name) {
  const probe = document.createElement('div');
  probe.style.cssText = 'position:absolute;left:0;top:0;';
  host.appendChild(probe);
  try {
    const raw = getComputedStyle(probe).getPropertyValue(name).trim();
    if (!raw) return null;
    const out = { raw };
    if (/^(inherit|initial|unset|revert)/.test(raw)) return { ...out, kind: 'raw' };
    if (/^-?[\d.]+m?s$/.test(raw)) {
      const n = parseFloat(raw);
      return { ...out, kind: 'duration', ms: raw.endsWith('ms') ? n : n * 1000 };
    }
    if (/^(cubic-bezier\(|ease|linear$|step)/.test(raw)) {
      probe.style.transitionTimingFunction = `var(${name})`;
      const t = getComputedStyle(probe).transitionTimingFunction;
      const m = t.match(/cubic-bezier\(([^)]*)\)/);
      if (m) return { ...out, kind: 'easing', points: m[1].split(',').map(Number) };
      if (EASE[t]) return { ...out, kind: 'easing', points: EASE[t] };
      return { ...out, kind: 'raw' };
    }
    if (CSS.supports('color', raw) && !/^[-\d.]/.test(raw)) {
      probe.style.backgroundColor = `var(${name})`;
      const c = getComputedStyle(probe).backgroundColor;
      return { ...out, kind: 'color', ...colorOf(c) };
    }
    if (CSS.supports('margin-left', raw) && /\d(px|rem)\b|calc|clamp|min\(|max\(/.test(raw) && !/%|\d(em|vw|vh|dvh|svh|ch|ex|lh|cqw)\b/.test(raw)) {
      const p16 = lenPx(probe, name, '16px'), p32 = lenPx(probe, name, '32px');
      if (!isNaN(p16) && !isNaN(p32)) {
        const rem = (p32 - p16) / 16, px = p16 - 16 * rem;
        return { ...out, kind: 'length', rem: round(rem), px: round(px) };
      }
    }
    if (CSS.supports('margin-left', `calc((${raw}) * 1px)`) && !/[a-z]/i.test(raw.replace(/calc/g, ''))) {
      probe.style.marginLeft = `calc((${raw}) * 1px)`;
      const v = parseFloat(getComputedStyle(probe).marginLeft);
      if (!isNaN(v)) return { ...out, kind: 'number', value: Math.round(v * 1e6) / 1e6 };
    }
    if (raw !== 'none' && CSS.supports('box-shadow', raw) && /\d/.test(raw) && !/^[\d.\s,px-]+$/.test(raw)) {
      const layers = parseShadow(probe, raw);
      if (layers.length) return { ...out, kind: 'shadow', layers };
    }
    return { ...out, kind: 'raw' };
  } finally { probe.remove(); }
}

const contexts = [[false, document.body], [true, document.body], [false, sidebar], [true, sidebar]];
const result = {};
for (const n of NAMES) result[n] = [];
for (const [dark, host] of contexts) {
  root.classList.toggle('dark', dark);
  for (const n of NAMES) result[n].push(resolve(host, n));
}
root.classList.remove('dark');
return { result, float: canvases.srgb.float, p3float: canvases['display-p3'].float };
})()
"""#

// MARK: - Browser driver

actor CDP {
    var nextId = 1
    var waiting: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    func register(_ c: CheckedContinuation<[String: Any], Never>) -> Int { let id = nextId; nextId += 1; waiting[id] = c; return id }
    func resolve(_ id: Int, _ msg: [String: Any]) { waiting.removeValue(forKey: id)?.resume(returning: msg) }
}

func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

struct Resolved { var tokens: [String: [[String: Any]?]]; var chrome: String; var float: Bool }

func resolveInBrowser(names: [String]) async throws -> Resolved {
    let base = NSHomeDirectory() + "/.t3/tools/chrome-headless-shell/mac-arm64"
    guard let version = (try? FileManager.default.contentsOfDirectory(atPath: base))?.sorted().last else { fail("chrome-headless-shell not found under \(base)") }
    let chrome = "\(base)/\(version)/chrome-headless-shell"
    guard FileManager.default.isExecutableFile(atPath: chrome) else { fail("not executable: \(chrome)") }

    let profile = FileManager.default.temporaryDirectory.appendingPathComponent("extract-tokens-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    let port = 9300 + Int.random(in: 0..<500)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: chrome)
    proc.arguments = ["--remote-debugging-port=\(port)", "--user-data-dir=\(profile.path)", "--hide-scrollbars",
                      "--window-size=1100,780", "--disable-gpu", "--no-first-run", "about:blank"]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()
    let pid = proc.processIdentifier   // only this process is ever signalled
    defer { if proc.isRunning { kill(pid, SIGTERM) }; try? FileManager.default.removeItem(at: profile) }

    var wsURL: URL?
    for _ in 0..<50 {
        if let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/json/list")!),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let page = list.first(where: { ($0["type"] as? String) == "page" }),
           let s = page["webSocketDebuggerUrl"] as? String { wsURL = URL(string: s); break }
        await sleep(0.2)
    }
    guard let wsURL else { fail("DevTools endpoint did not come up") }
    let ws = URLSession.shared.webSocketTask(with: wsURL)
    ws.maximumMessageSize = 256 * 1024 * 1024
    ws.resume()
    let cdp = CDP()
    let reader = Task {
        while true {
            guard case .string(let text) = try await ws.receive(),
                  let msg = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            if let id = msg["id"] as? Int { await cdp.resolve(id, msg) }
        }
    }
    defer { reader.cancel(); ws.cancel(with: .normalClosure, reason: nil) }

    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let msg = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            _ = Task {
                let id = await cdp.register(c)
                let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
                try await ws.send(.string(String(decoding: data, as: UTF8.self)))
            }
        }
        if let err = msg["error"] { fail("CDP \(method) error: \(err)") }
        return (msg["result"] as? [String: Any]) ?? [:]
    }
    func evaluate(_ expr: String) async throws -> Any? {
        let r = try await send("Runtime.evaluate", ["expression": expr, "awaitPromise": true, "returnByValue": true])
        if let ex = r["exceptionDetails"] { fail("page exception: \(ex)") }
        return (r["result"] as? [String: Any])?["value"]
    }

    try await send("Page.enable")
    // Load the stylesheet into a blank page as a <style> element.
    let cssLiteral = String(decoding: try JSONSerialization.data(withJSONObject: [css]), as: UTF8.self)
    _ = try await evaluate("(() => { const s = document.createElement('style'); s.textContent = \(cssLiteral)[0]; document.head.appendChild(s); return true; })()")

    let namesJSON = String(decoding: try JSONSerialization.data(withJSONObject: names), as: UTF8.self)
    let script = pageScript.replacingOccurrences(of: "__NAMES__", with: namesJSON)
    guard let out = try await evaluate(script) as? [String: Any],
          let result = out["result"] as? [String: [Any]] else { fail("page script returned nothing") }
    var tokens: [String: [[String: Any]?]] = [:]
    for (k, v) in result { tokens[k] = v.map { $0 as? [String: Any] } }
    return Resolved(tokens: tokens, chrome: version, float: (out["float"] as? Bool) ?? false)
}

// MARK: - Resolve

let names = collectNames(css)
var resolved: Resolved
if let loadPath {
    let d = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: loadPath))) as! [String: Any]
    resolved = Resolved(tokens: (d["tokens"] as! [String: [Any]]).mapValues { $0.map { $0 as? [String: Any] } },
                        chrome: d["chrome"] as! String, float: d["float"] as! Bool)
} else {
    resolved = try await resolveInBrowser(names: names)
}

// MARK: - Model

typealias Ctx = [String: Any]
func dbl(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
func vec(_ v: Any?) -> [Double] { ((v as? [Any]) ?? []).map(dbl) }

/// Index of the context used when a token is not context dependent: light, else first that resolved.
func primary(_ ctxs: [Ctx?]) -> Ctx? { ctxs.compactMap { $0 }.first }

let swiftKeywords: Set<String> = ["default", "in", "is", "as", "class", "struct", "enum", "func", "let", "var", "init", "self", "super",
                                  "return", "if", "else", "for", "while", "switch", "case", "do", "try", "catch", "throw", "import",
                                  "protocol", "extension", "static", "public", "private", "internal", "where", "true", "false", "nil", "repeat", "break", "continue", "operator", "subscript", "Type", "Protocol"]

/// "card-foreground" -> "cardForeground"; a leading digit gets an underscore ("2xl" -> "_2xl").
func camel(_ s: String) -> String {
    let parts = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init).filter { !$0.isEmpty }
    var out = ""
    for (i, p) in parts.enumerated() {
        out += i == 0 ? p.prefix(1).lowercased() + p.dropFirst() : p.prefix(1).uppercased() + p.dropFirst()
    }
    if let f = out.first, f.isNumber { out = "_" + out }
    return swiftKeywords.contains(out) ? "`\(out)`" : out
}

func num(_ v: Double) -> String {
    var s = String(format: "%.4f", v)
    while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
    return s == "-0.0" ? "0.0" : s
}

func hex(_ c: [Double]) -> String {
    let b = c.prefix(3).map { Int(max(0, min(255, ($0 * 255).rounded()))) }
    var s = String(format: "#%02x%02x%02x", b[0], b[1], b[2])
    if c.count > 3, c[3] < 0.9999 { s += String(format: "%02x", Int(max(0, min(255, (c[3] * 255).rounded())))) }
    return s
}

struct Entry { let css: String; let swift: String; let ctx: [Ctx?] }

let transparent: Ctx = ["kind": "color", "srgb": [0, 0, 0, 0], "p3": [0, 0, 0, 0], "css": "transparent"]
func kind(_ c: Ctx?) -> String? { c?["kind"] as? String }

// MARK: - Classification

var colors: [Entry] = []          // semantic colors (Palette)
var baseColors: [Entry] = []      // --color-*
var radii: [Entry] = [], shadows: [Entry] = [], easings: [Entry] = [], durations: [Entry] = []
var remLengths: [Entry] = [], pxLengths: [Entry] = [], numbers: [Entry] = [], raws: [Entry] = []
var textSizes: [String: Entry] = [:], textLeading: [String: Entry] = [:]
var spacing: Entry?
var unresolved: [String] = []
var partialColor: [String] = []
var contextDependent: [String] = []

for name in names.sorted() {
    guard let ctx = resolved.tokens[name], let p = primary(ctx) else { unresolved.append(name); continue }
    let css = name
    let k = kind(p)!
    let bare = String(name.dropFirst(2))
    let e = Entry(css: css, swift: camel(bare), ctx: ctx)
    if k != "color", Set(ctx.compactMap { $0?["raw"] as? String }).count > 1 { contextDependent.append(name) }
    switch k {
    case "color":
        if bare.hasPrefix("color-") {
            baseColors.append(Entry(css: css, swift: String(bare.dropFirst(6)), ctx: ctx))
        } else {
            if ctx.contains(where: { kind($0) != "color" }) { partialColor.append(name) }
            colors.append(e)
        }
    case "length":
        if name == "--spacing" { spacing = e }
        else if bare == "radius" || bare.hasPrefix("radius-") { radii.append(Entry(css: css, swift: bare == "radius" ? "base" : camel(String(bare.dropFirst(7))), ctx: ctx)) }
        else if bare.hasPrefix("text-") && !bare.contains("--") { textSizes[String(bare.dropFirst(5))] = e }
        else if dbl(p["rem"]) != 0 { remLengths.append(e) } else { pxLengths.append(e) }
    case "number":
        if bare.hasPrefix("text-") && bare.hasSuffix("--line-height") {
            textLeading[String(bare.dropFirst(5).dropLast(13))] = e
        } else { numbers.append(e) }
    case "shadow": shadows.append(e)
    case "easing": easings.append(e)
    case "duration": durations.append(e)
    default: raws.append(e)
    }
}
func sorted(_ a: [Entry]) -> [Entry] { a.sorted { $0.swift < $1.swift } }
colors = sorted(colors); baseColors.sort { $0.swift < $1.swift }

// MARK: - Swift output

func colorExpr(_ c: Ctx?) -> String {
    let c = (kind(c) == "color" ? c : transparent)!
    let s = vec(c["srgb"]), p = vec(c["p3"])
    return "c(" + (s + p).map(num).joined(separator: ", ") + ")"
}
func doc(_ e: Entry, _ extra: String = "") -> String { "    /// `\(e.css)`\(extra)" }

var out = """
// Generated by scripts/extract-tokens from design/t3-source/main.css (T3 \(t3Version)). Do not edit.
// Resolved by chrome-headless-shell \(resolved.chrome). Canvas readback precision is about 0.0005 per channel.
import CoreGraphics
import Foundation

/// A color resolved in both sRGB and Display P3, components 0...1 (r, g, b, a).
public struct TokenColor: Sendable, Hashable {
    public let srgb: SIMD4<Double>
    public let displayP3: SIMD4<Double>
    public init(srgb: SIMD4<Double>, displayP3: SIMD4<Double>) { self.srgb = srgb; self.displayP3 = displayP3 }
}

/// One layer of a CSS box-shadow. Offsets and radii are in px, color is sRGB RGBA.
public struct ShadowLayer: Sendable, Hashable {
    public let inset: Bool
    public let x: CGFloat
    public let y: CGFloat
    public let blur: CGFloat
    public let spread: CGFloat
    public let color: SIMD4<Double>
}

/// A font size and line height, both in rem.
public struct TextStyle: Sendable, Hashable {
    public let size: CGFloat
    public let lineHeight: CGFloat
}

private func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double, _ pr: Double, _ pg: Double, _ pb: Double, _ pa: Double) -> TokenColor {
    TokenColor(srgb: SIMD4(r, g, b, a), displayP3: SIMD4(pr, pg, pb, pa))
}
private func l(_ inset: Bool, _ x: CGFloat, _ y: CGFloat, _ blur: CGFloat, _ spread: CGFloat, _ r: Double, _ g: Double, _ b: Double, _ a: Double) -> ShadowLayer {
    ShadowLayer(inset: inset, x: x, y: y, blur: blur, spread: spread, color: SIMD4(r, g, b, a))
}

/// Every semantic color token, resolved for one context (light, dark, or inside the sidebar).
public struct Palette: Sendable {

"""
for e in colors { out += "\(doc(e))\n    public let \(e.swift): TokenColor\n" }
out += "}\n\npublic enum Tokens {\n"

func palette(_ name: String, _ idx: Int, _ label: String) -> String {
    var s = "    /// Semantic colors, \(label).\n    public static let \(name) = Palette(\n"
    s += colors.map { "        \($0.swift): \(colorExpr($0.ctx[idx]))" }.joined(separator: ",\n")
    return s + "\n    )\n\n"
}
out += palette("light", 0, "light theme") + palette("dark", 1, "dark theme")
out += palette("sidebarLight", 2, "light theme inside `[data-app-sidebar]`") + palette("sidebarDark", 3, "dark theme inside `[data-app-sidebar]`")

out += "    /// The `--color-*` base palette (light context), keyed without the prefix, for example \"zinc-500\".\n"
out += "    public static let baseColors: [String: TokenColor] = [\n"
out += baseColors.map { "        \"\($0.swift)\": \(colorExpr(primary($0.ctx)))" }.joined(separator: ",\n") + "\n    ]\n\n"

func remValue(_ e: Entry) -> Double { dbl(primary(e.ctx)?["rem"]) }
func pxValue(_ e: Entry) -> Double { dbl(primary(e.ctx)?["px"]) }

out += "    /// Corner radii in rem. Where the CSS adds a fixed px offset, it is exposed as `<name>PxOffset` and does not scale with the root size.\n    public enum Radius {\n"
for e in sorted(radii) {
    out += "    " + doc(e, " = `\(primary(e.ctx)!["raw"] as! String)`") + "\n    "
    out += "    public static let \(e.swift): CGFloat = \(num(remValue(e)))\n"
    if pxValue(e) != 0 { out += "        /// Fixed px part of `\(e.css)`.\n        public static let \(e.swift)PxOffset: CGFloat = \(num(pxValue(e)))\n" }
}
out += "    }\n\n    public enum Spacing {\n"
if let s = spacing { out += "    " + doc(s, " (rem)") + "\n        public static let unit: CGFloat = \(num(remValue(s)))\n" }
out += "    }\n\n    /// Font sizes with their paired line heights, in rem.\n    public enum Text {\n"
for key in textSizes.keys.sorted(by: { camel($0) < camel($1) }) {
    let e = textSizes[key]!
    let size = remValue(e)
    var lh = size * 1.5, note = "no paired line height in the CSS, 1.5 assumed"
    if let l = textLeading[key], let lp = primary(l.ctx) {
        lh = (lp["value"] as? NSNumber).map { $0.doubleValue * size } ?? size
        note = "`\(l.css)` = `\(lp["raw"] as! String)`"
    }
    out += "    " + doc(e, ", \(note)") + "\n        public static let \(camel(key)) = TextStyle(size: \(num(size)), lineHeight: \(num(lh)))\n"
}
out += "    }\n\n    public enum Shadow {\n"
for e in sorted(shadows) {
    let layers = (primary(e.ctx)!["layers"] as! [Any]).map { $0 as! Ctx }
    out += "    " + doc(e, " = `\(primary(e.ctx)!["raw"] as! String)`") + "\n        public static let \(e.swift): [ShadowLayer] = [\n"
    out += layers.map { L in
        let col = vec(L["color"]).map(num).joined(separator: ", ")
        return "            l(\(L["inset"] as! Bool), \(num(dbl(L["x"]))), \(num(dbl(L["y"]))), \(num(dbl(L["blur"]))), \(num(dbl(L["spread"]))), \(col))"
    }.joined(separator: ",\n") + "\n        ]\n"
}
out += "    }\n\n    /// Cubic bezier control points (x1, y1, x2, y2).\n    public enum Easing {\n"
for e in sorted(easings) {
    let p = vec(primary(e.ctx)!["points"]).map(num).joined(separator: ", ")
    out += "    " + doc(e, " = `\(primary(e.ctx)!["raw"] as! String)`") + "\n        public static let \(e.swift): (x1: Double, y1: Double, x2: Double, y2: Double) = (\(p))\n"
}
out += "    }\n\n    /// Durations in seconds.\n    public enum Duration {\n"
for e in sorted(durations) {
    out += "    " + doc(e, " = `\(primary(e.ctx)!["raw"] as! String)`") + "\n        public static let \(e.swift): Double = \(num(dbl(primary(e.ctx)!["ms"]) / 1000))\n"
}
out += "    }\n\n    /// Other lengths declared in rem. Multiply by the user's root font size.\n    public enum LengthRem {\n"
for e in sorted(remLengths) { out += "    " + doc(e, " = `\(primary(e.ctx)!["raw"] as! String)`") + "\n        public static let \(e.swift): CGFloat = \(num(remValue(e)))\n" }
out += "    }\n\n    /// Other lengths declared in px (light context value).\n    public enum LengthPx {\n"
for e in sorted(pxLengths) { out += "    " + doc(e, " = `\(primary(e.ctx)!["raw"] as! String)`") + "\n        public static let \(e.swift): CGFloat = \(num(pxValue(e)))\n" }
out += "    }\n\n    /// Unitless numbers such as font weights and line-height ratios.\n    public enum Number {\n"
for e in sorted(numbers) { out += "    " + doc(e, " = `\(primary(e.ctx)!["raw"] as! String)`") + "\n        public static let \(e.swift): Double = \(num(dbl(primary(e.ctx)!["value"])))\n" }
out += "    }\n\n    /// Tokens that are not colors, lengths, numbers, shadows, easings or durations. Raw CSS text (light context).\n    public enum Raw {\n"
for e in sorted(raws) {
    let r = (primary(e.ctx)!["raw"] as! String)
    let lit = r.count > 400 ? String(r.prefix(0)) + "(omitted, \(r.count) characters)" : r
    let esc = lit.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    out += "    " + doc(e) + "\n        public static let \(e.swift) = \"\(esc)\"\n"
}
out += "    }\n}\n"

try FileManager.default.createDirectory(at: swiftOut.deletingLastPathComponent(), withIntermediateDirectories: true)
try out.write(to: swiftOut, atomically: true, encoding: .utf8)

// MARK: - Token sheet

func cell(_ c: Ctx?) -> String { kind(c) == "color" ? "`\(hex(vec(c!["srgb"])))`" : "-" }
var md = """
# Design tokens

Generated by `scripts/extract-tokens` from `design/t3-source/main.css` (T3 \(t3Version)), resolved by chrome-headless-shell \(resolved.chrome). Do not edit by hand. Colors are sRGB hex (`#rrggbbaa` when not opaque). The Swift file also carries Display P3 values. Light and dark are the document themes. "Sidebar" columns are the same token resolved inside an element with `data-app-sidebar`, which overrides part of the palette.

Counts: \(colors.count) semantic colors, \(baseColors.count) base colors, \(radii.count) radii, \(textSizes.count) text sizes, \(shadows.count) shadows, \(easings.count) easings, \(durations.count) durations, \(remLengths.count + pxLengths.count + (spacing == nil ? 0 : 1)) other lengths, \(numbers.count) numbers, \(raws.count) raw strings.

## Semantic colors

| CSS name | Light | Dark | Sidebar light | Sidebar dark | Swift |
| --- | --- | --- | --- | --- | --- |

"""
for e in colors { md += "| `\(e.css)` | \(cell(e.ctx[0])) | \(cell(e.ctx[1])) | \(cell(e.ctx[2])) | \(cell(e.ctx[3])) | `Palette.\(e.swift)` |\n" }
md += "\n## Base colors\n\n| CSS name | Light | Dark | Swift |\n| --- | --- | --- | --- |\n"
for e in baseColors { md += "| `\(e.css)` | \(cell(e.ctx[0])) | \(cell(e.ctx[1])) | `Tokens.baseColors[\"\(e.swift)\"]` |\n" }
md += "\n## Radius (rem)\n\n| CSS name | Value | Resolved | Swift |\n| --- | --- | --- | --- |\n"
for e in sorted(radii) { md += "| `\(e.css)` | `\(primary(e.ctx)!["raw"] as! String)` | \(num(remValue(e))) rem\(pxValue(e) != 0 ? " + \(num(pxValue(e))) px" : "") | `Tokens.Radius.\(e.swift)` |\n" }
md += "\n## Spacing\n\n| CSS name | Value | Swift |\n| --- | --- | --- |\n"
if let s = spacing { md += "| `\(s.css)` | `\(primary(s.ctx)!["raw"] as! String)` | `Tokens.Spacing.unit` |\n" }
md += "\n## Text (rem)\n\n| CSS name | Size | Line height | Swift |\n| --- | --- | --- | --- |\n"
for key in textSizes.keys.sorted(by: { camel($0) < camel($1) }) {
    let e = textSizes[key]!; let size = remValue(e)
    let lh = textLeading[key].flatMap { primary($0.ctx)?["value"] as? NSNumber }.map { $0.doubleValue * size }
    md += "| `\(e.css)` | \(num(size)) | \(lh.map(num) ?? "none") | `Tokens.Text.\(camel(key))` |\n"
}
md += "\n## Shadows\n\n| CSS name | Value | Swift |\n| --- | --- | --- |\n"
for e in sorted(shadows) { md += "| `\(e.css)` | `\(primary(e.ctx)!["raw"] as! String)` | `Tokens.Shadow.\(e.swift)` |\n" }
md += "\n## Easing\n\n| CSS name | Control points | Swift |\n| --- | --- | --- |\n"
for e in sorted(easings) { md += "| `\(e.css)` | \(vec(primary(e.ctx)!["points"]).map(num).joined(separator: ", ")) | `Tokens.Easing.\(e.swift)` |\n" }
md += "\n## Duration\n\n| CSS name | Value | Swift |\n| --- | --- | --- |\n"
for e in sorted(durations) { md += "| `\(e.css)` | \(num(dbl(primary(e.ctx)!["ms"]))) ms | `Tokens.Duration.\(e.swift)` |\n" }
md += "\n## Other lengths\n\n| CSS name | Value | Unit | Swift |\n| --- | --- | --- | --- |\n"
for e in sorted(remLengths) { md += "| `\(e.css)` | `\(primary(e.ctx)!["raw"] as! String)` | rem | `Tokens.LengthRem.\(e.swift)` |\n" }
for e in sorted(pxLengths) { md += "| `\(e.css)` | `\(primary(e.ctx)!["raw"] as! String)` | px | `Tokens.LengthPx.\(e.swift)` |\n" }
md += "\n## Numbers\n\n| CSS name | Value | Swift |\n| --- | --- | --- |\n"
for e in sorted(numbers) { md += "| `\(e.css)` | `\(primary(e.ctx)!["raw"] as! String)` | `Tokens.Number.\(e.swift)` |\n" }
md += "\n## Raw strings\n\n| CSS name | Value | Swift |\n| --- | --- | --- |\n"
for e in sorted(raws) {
    var r = primary(e.ctx)!["raw"] as! String
    if r.count > 80 { r = String(r.prefix(77)) + "..." }
    md += "| `\(e.css)` | `\(r.replacingOccurrences(of: "|", with: "\\|"))` | `Tokens.Raw.\(e.swift)` |\n"
}
md += "\n## Not resolved\n\nDeclared in the stylesheet but with no value on `:root` or `[data-app-sidebar]` in any context (component-scoped or set at runtime), so they are not extracted:\n\n"
md += unresolved.map { "`\($0)`" }.joined(separator: ", ") + "\n"
if !partialColor.isEmpty { md += "\nColors that resolve in only some contexts (missing ones are emitted as transparent): " + partialColor.map { "`\($0)`" }.joined(separator: ", ") + "\n" }
if !contextDependent.isEmpty { md += "\nNon-color tokens whose value differs between contexts (the light value is emitted): " + contextDependent.map { "`\($0)`" }.joined(separator: ", ") + "\n" }
try FileManager.default.createDirectory(at: docOut.deletingLastPathComponent(), withIntermediateDirectories: true)
try md.write(to: docOut, atomically: true, encoding: .utf8)

// MARK: - Main

if let dumpPath {
    let obj: [String: Any] = ["tokens": resolved.tokens.mapValues { $0.map { ($0 as Any?) ?? NSNull() } }, "chrome": resolved.chrome, "float": resolved.float]
    try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dumpPath))
}
print("semantic colors \(colors.count), base colors \(baseColors.count), radius \(radii.count), text \(textSizes.count), shadow \(shadows.count), easing \(easings.count), duration \(durations.count), rem \(remLengths.count), px \(pxLengths.count), numbers \(numbers.count), raw \(raws.count), unresolved \(unresolved.count)")
print("partial colors: \(partialColor.count), context-dependent non-colors: \(contextDependent)")
print("wrote \(swiftOut.path)\nwrote \(docOut.path)")
