import CoreGraphics
import Foundation

public struct SVGPathError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var offset: Int
    public var description: String { "SVG path error at \(offset): \(message)" }
}

/// Minimal SVG path `d` parser producing a CGPath (y axis stays SVG-down).
/// Supports M m L l H h V v C c S s Q q T t A a Z z with implicit repetition.
public enum SVGPath {
    public static func parse(_ d: String) throws -> CGPath {
        var p = Parser(Array(d.utf8))
        return try p.run()
    }

    private struct Parser {
        let s: [UInt8]
        var i = 0
        let path = CGMutablePath()
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastCubicCtrl: CGPoint?
        var lastQuadCtrl: CGPoint?

        init(_ s: [UInt8]) { self.s = s }

        func err(_ m: String) -> SVGPathError { SVGPathError(message: m, offset: i) }

        mutating func skipSep() {
            while i < s.count, s[i] == 0x20 || s[i] == 0x2C || s[i] == 0x0A || s[i] == 0x09 || s[i] == 0x0D { i += 1 }
        }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

        mutating func number() throws -> Double {
            skipSep()
            let b = i
            if i < s.count, s[i] == 0x2B || s[i] == 0x2D { i += 1 }
            var digits = 0
            while i < s.count, isDigit(s[i]) { i += 1; digits += 1 }
            if i < s.count, s[i] == 0x2E {
                i += 1
                while i < s.count, isDigit(s[i]) { i += 1; digits += 1 }
            }
            guard digits > 0 else { i = b; throw err("expected number") }
            if i < s.count, s[i] == 0x65 || s[i] == 0x45 {
                var j = i + 1
                if j < s.count, s[j] == 0x2B || s[j] == 0x2D { j += 1 }
                if j < s.count, isDigit(s[j]) {
                    while j < s.count, isDigit(s[j]) { j += 1 }
                    i = j
                }
            }
            guard let v = Double(String(decoding: s[b..<i], as: UTF8.self)) else { i = b; throw err("bad number") }
            return v
        }

        mutating func flag() throws -> Bool {
            skipSep()
            guard i < s.count, s[i] == 0x30 || s[i] == 0x31 else { throw err("expected arc flag") }
            defer { i += 1 }
            return s[i] == 0x31
        }

        mutating func hasNumber() -> Bool {
            skipSep()
            guard i < s.count else { return false }
            let c = s[i]
            return isDigit(c) || c == 0x2E || c == 0x2D || c == 0x2B
        }

        mutating func run() throws -> CGPath {
            var cmd: UInt8 = 0
            var started = false
            while true {
                skipSep()
                if i >= s.count { break }
                let c = s[i]
                if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
                    cmd = c; i += 1
                    if !started && cmd != 0x4D && cmd != 0x6D { throw err("path must start with M") }
                    started = true
                    if cmd == 0x5A || cmd == 0x7A {
                        path.closeSubpath(); cur = start
                        lastCubicCtrl = nil; lastQuadCtrl = nil
                        continue
                    }
                } else if !started || cmd == 0 || cmd == 0x5A || cmd == 0x7A {
                    throw err("unexpected character")
                } else if !hasNumber() {
                    throw err("unexpected character")
                }
                try segment(cmd)
                // implicit repetition: M becomes L, m becomes l
                if cmd == 0x4D { cmd = 0x4C } else if cmd == 0x6D { cmd = 0x6C }
                while hasNumber() {
                    try segment(cmd)
                }
            }
            return path.copy() ?? path
        }

        mutating func pt(_ rel: Bool) throws -> CGPoint {
            let x = try number(), y = try number()
            return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }

        mutating func segment(_ c: UInt8) throws {
            let rel = c >= 0x61
            let up = rel ? c - 0x20 : c
            var newCubic: CGPoint?
            var newQuad: CGPoint?
            switch up {
            case 0x4D: // M
                let p = try pt(rel); path.move(to: p); cur = p; start = p
            case 0x4C: // L
                let p = try pt(rel); path.addLine(to: p); cur = p
            case 0x48: // H
                let x = try number(); cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
            case 0x56: // V
                let y = try number(); cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
            case 0x43: // C
                let a = try pt(rel), b = try pt(rel), e = try pt(rel)
                path.addCurve(to: e, control1: a, control2: b); cur = e; newCubic = b
            case 0x53: // S
                let a = lastCubicCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let b = try pt(rel), e = try pt(rel)
                path.addCurve(to: e, control1: a, control2: b); cur = e; newCubic = b
            case 0x51: // Q
                let a = try pt(rel), e = try pt(rel)
                path.addQuadCurve(to: e, control: a); cur = e; newQuad = a
            case 0x54: // T
                let a = lastQuadCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let e = try pt(rel)
                path.addQuadCurve(to: e, control: a); cur = e; newQuad = a
            case 0x41: // A
                let rx = try number(), ry = try number(), rot = try number()
                let large = try flag(), sweep = try flag()
                let e = try pt(rel)
                arc(from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: e)
                cur = e
            default:
                throw err("unknown command \(Character(UnicodeScalar(c)))")
            }
            lastCubicCtrl = newCubic
            lastQuadCtrl = newQuad
        }

        /// SVG implementation notes F.6: endpoint to center parameterisation, split into <= 90 degree cubics.
        func arc(from p0: CGPoint, rx rx0: Double, ry ry0: Double, rotation: Double, large: Bool, sweep: Bool, to p1: CGPoint) {
            if p0 == p1 { return }
            var rx = abs(rx0), ry = abs(ry0)
            if rx == 0 || ry == 0 { path.addLine(to: p1); return }
            let phi = rotation * .pi / 180
            let cp = cos(phi), sp = sin(phi)
            let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
            let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 { let k = lambda.squareRoot(); rx *= k; ry *= k }
            let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
            var coef = den == 0 ? 0 : (max(0, num / den)).squareRoot()
            if large == sweep { coef = -coef }
            let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
            let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2
            let cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
            func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
                atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            }
            let th1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
            var dth = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
            if !sweep && dth > 0 { dth -= 2 * .pi } else if sweep && dth < 0 { dth += 2 * .pi }
            let n = max(1, Int((abs(dth) / (.pi / 2) - 1e-9).rounded(.up)))
            let step = dth / Double(n)
            let t = 4.0 / 3.0 * tan(step / 4)
            var a = th1
            for k in 0..<n {
                let b = a + step
                let ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b)
                func map(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: cp * rx * x - sp * ry * y + cx, y: sp * rx * x + cp * ry * y + cy)
                }
                let c1 = map(ca - t * sa, sa + t * ca)
                let c2 = map(cb + t * sb, sb - t * cb)
                let end = k == n - 1 ? p1 : map(cb, sb)
                path.addCurve(to: end, control1: c1, control2: c2)
                a = b
            }
        }
    }
}

extension IconShape {
    /// CGPath in viewBox coordinates (y down), without paint or transforms.
    public func cgPath() throws -> CGPath {
        switch self {
        case .path(let d):
            return try SVGPath.parse(d)
        case .circle(let cx, let cy, let r):
            return CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
        case .ellipse(let cx, let cy, let rx, let ry):
            return CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        case .rect(let x, let y, let w, let h, let rx, let ry):
            let r = CGRect(x: x, y: y, width: w, height: h)
            if rx <= 0 && ry <= 0 { return CGPath(rect: r, transform: nil) }
            return CGPath(roundedRect: r, cornerWidth: min(rx, w / 2), cornerHeight: min(ry, h / 2), transform: nil)
        case .line(let x1, let y1, let x2, let y2):
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2))
            return p
        case .polyline(let pts):
            return try Self.poly(pts, close: false)
        case .polygon(let pts):
            return try Self.poly(pts, close: true)
        }
    }

    private static func poly(_ pts: [Double], close: Bool) throws -> CGPath {
        guard pts.count >= 4, pts.count % 2 == 0 else { throw SVGPathError(message: "bad points", offset: 0) }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: pts[0], y: pts[1]))
        var k = 2
        while k < pts.count { p.addLine(to: CGPoint(x: pts[k], y: pts[k + 1])); k += 2 }
        if close { p.closeSubpath() }
        return p
    }
}

extension IconElement {
    public func cgPath() throws -> CGPath { try shape.cgPath() }
}
