// QR Code generator, a Swift port of Project Nayuki's library (MIT License), the same code T3 vendors as
// packages/shared/src/qrCode.ts. Copyright (c) Project Nayuki. https://www.nayuki.io/page/qr-code-generator-library
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
// to permit persons to whom the Software is furnished to do so, subject to the following conditions: the above
// copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software. The Software is provided "as is", without warranty of any kind.
//
// Only `encodeText` with T3's defaults is ported (versions 1 to 40, automatic mask, boosted ECC level),
// because that is all QRCodeSvg calls. CoreImage's generator picks other modes and masks, so its
// matrices differ from T3's.

public struct QRCode: Sendable {
    public enum Ecc: Int, Sendable {
        case low, medium, quartile, high
        var formatBits: Int { [1, 0, 3, 2][rawValue] }
    }

    public let version: Int
    public let size: Int
    public let ecc: Ecc
    public private(set) var mask: Int
    private var modules: [[Bool]]
    private var isFunction: [[Bool]]

    public func module(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < size && y >= 0 && y < size && modules[y][x]
    }

    // MARK: Encoding

    public static func encodeText(_ text: String, ecc: Ecc) -> QRCode? {
        encodeSegments(Segment.make(text), ecc: ecc)
    }

    static func encodeSegments(_ segs: [Segment], ecc: Ecc) -> QRCode? {
        var version = 1, used = 0
        while true {
            let capacity = numDataCodewords(version, ecc) * 8
            if let bits = Segment.totalBits(segs, version), bits <= capacity { used = bits; break }
            if version >= 40 { return nil }
            version += 1
        }
        var ecl = ecc
        for boosted in [Ecc.medium, .quartile, .high] where used <= numDataCodewords(version, boosted) * 8 { ecl = boosted }

        var bb: [Bool] = []
        for seg in segs {
            bb.append(bits: seg.mode.bits, count: 4)
            bb.append(bits: seg.numChars, count: seg.mode.charCountBits(version))
            bb += seg.data
        }
        let capacity = numDataCodewords(version, ecl) * 8
        bb.append(bits: 0, count: min(4, capacity - bb.count))
        bb.append(bits: 0, count: (8 - bb.count % 8) % 8)
        var pad = 0xEC
        while bb.count < capacity { bb.append(bits: pad, count: 8); pad ^= 0xEC ^ 0x11 }

        var codewords = [UInt8](repeating: 0, count: bb.count / 8)
        for (i, bit) in bb.enumerated() where bit { codewords[i >> 3] |= UInt8(1 << (7 - (i & 7))) }
        return QRCode(version: version, ecc: ecl, data: codewords)
    }

    private init(version: Int, ecc: Ecc, data: [UInt8]) {
        self.version = version
        self.ecc = ecc
        size = version * 4 + 17
        modules = Array(repeating: Array(repeating: false, count: size), count: size)
        isFunction = modules
        mask = 0
        drawFunctionPatterns()
        drawCodewords(addEccAndInterleave(data))
        var best = 0, minPenalty = Int.max
        for m in 0..<8 {
            applyMask(m)
            drawFormatBits(m)
            let p = penaltyScore()
            if p < minPenalty { best = m; minPenalty = p }
            applyMask(m) // XOR undoes it
        }
        mask = best
        applyMask(best)
        drawFormatBits(best)
        isFunction = []
    }

    // MARK: Function patterns

    private mutating func set(_ x: Int, _ y: Int, _ dark: Bool) {
        modules[y][x] = dark
        isFunction[y][x] = true
    }

    private mutating func drawFunctionPatterns() {
        for i in 0..<size {
            set(6, i, i % 2 == 0)
            set(i, 6, i % 2 == 0)
        }
        drawFinder(3, 3); drawFinder(size - 4, 3); drawFinder(3, size - 4)
        let align = alignmentPositions()
        let n = align.count
        for i in 0..<n {
            for j in 0..<n where !(i == 0 && j == 0 || i == 0 && j == n - 1 || i == n - 1 && j == 0) {
                drawAlignment(align[i], align[j])
            }
        }
        drawFormatBits(0)
        drawVersion()
    }

    private mutating func drawFormatBits(_ mask: Int) {
        let data = ecc.formatBits << 3 | mask
        var rem = data
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        let bits = (data << 10 | rem) ^ 0x5412
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 != 0 }
        for i in 0...5 { set(8, i, bit(i)) }
        set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8))
        for i in 9..<15 { set(14 - i, 8, bit(i)) }
        for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
        set(8, size - 8, true)
    }

    private mutating func drawVersion() {
        guard version >= 7 else { return }
        var rem = version
        for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
        let bits = version << 12 | rem
        for i in 0..<18 {
            let dark = (bits >> i) & 1 != 0
            let a = size - 11 + i % 3, b = i / 3
            set(a, b, dark); set(b, a, dark)
        }
    }

    private mutating func drawFinder(_ x: Int, _ y: Int) {
        for dy in -4...4 {
            for dx in -4...4 {
                let dist = max(abs(dx), abs(dy)), xx = x + dx, yy = y + dy
                if xx >= 0, xx < size, yy >= 0, yy < size { set(xx, yy, dist != 2 && dist != 4) }
            }
        }
    }

    private mutating func drawAlignment(_ x: Int, _ y: Int) {
        for dy in -2...2 { for dx in -2...2 { set(x + dx, y + dy, max(abs(dx), abs(dy)) != 1) } }
    }

    private func alignmentPositions() -> [Int] {
        guard version > 1 else { return [] }
        let num = version / 7 + 2
        let step = version == 32 ? 26 : Int((Double(version * 4 + 4) / Double(num * 2 - 2)).rounded(.up)) * 2
        var result = [6]
        var pos = size - 7
        while result.count < num { result.insert(pos, at: 1); pos -= step }
        return result
    }

    // MARK: Codewords

    private func addEccAndInterleave(_ data: [UInt8]) -> [UInt8] {
        let numBlocks = Self.numBlocks[ecc.rawValue][version]
        let eccLen = Self.eccPerBlock[ecc.rawValue][version]
        let rawCodewords = Self.numRawDataModules(version) / 8
        let numShort = numBlocks - rawCodewords % numBlocks
        let shortLen = rawCodewords / numBlocks
        let divisor = Self.reedSolomonDivisor(eccLen)
        var blocks: [[UInt8]] = []
        var k = 0
        for i in 0..<numBlocks {
            let len = shortLen - eccLen + (i < numShort ? 0 : 1)
            var dat = Array(data[k..<k + len])
            k += len
            let ecc = Self.reedSolomonRemainder(dat, divisor)
            if i < numShort { dat.append(0) }
            blocks.append(dat + ecc)
        }
        var result: [UInt8] = []
        for i in 0..<blocks[0].count {
            for (j, block) in blocks.enumerated() where i != shortLen - eccLen || j >= numShort {
                result.append(block[i])
            }
        }
        return result
    }

    private mutating func drawCodewords(_ data: [UInt8]) {
        var i = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vert in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = (right + 1) & 2 == 0
                    let y = upward ? size - 1 - vert : vert
                    if !isFunction[y][x], i < data.count * 8 {
                        modules[y][x] = (data[i >> 3] >> (7 - (i & 7))) & 1 != 0
                        i += 1
                    }
                }
            }
            right -= 2
        }
    }

    private mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size where !isFunction[y][x] {
                let invert: Bool
                switch mask {
                case 0: invert = (x + y) % 2 == 0
                case 1: invert = y % 2 == 0
                case 2: invert = x % 3 == 0
                case 3: invert = (x + y) % 3 == 0
                case 4: invert = (x / 3 + y / 2) % 2 == 0
                case 5: invert = x * y % 2 + x * y % 3 == 0
                case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                if invert { modules[y][x].toggle() }
            }
        }
    }

    // MARK: Penalty

    private func penaltyScore() -> Int {
        var result = 0
        for axis in 0..<2 {
            for a in 0..<size {
                var runColor = false, run = 0
                var history = [Int](repeating: 0, count: 7)
                for b in 0..<size {
                    let color = axis == 0 ? modules[a][b] : modules[b][a]
                    if color == runColor {
                        run += 1
                        if run == 5 { result += 3 } else if run > 5 { result += 1 }
                    } else {
                        addHistory(run, &history)
                        if !runColor { result += countPatterns(history) * 40 }
                        runColor = color
                        run = 1
                    }
                }
                result += terminateAndCount(runColor, run, &history) * 40
            }
        }
        for y in 0..<size - 1 {
            for x in 0..<size - 1 {
                let c = modules[y][x]
                if c == modules[y][x + 1], c == modules[y + 1][x], c == modules[y + 1][x + 1] { result += 3 }
            }
        }
        let dark = modules.reduce(0) { $0 + $1.filter { $0 }.count }
        let total = size * size
        let k = Int((Double(abs(dark * 20 - total * 10)) / Double(total)).rounded(.up)) - 1
        return result + k * 10
    }

    private func countPatterns(_ h: [Int]) -> Int {
        let n = h[1]
        let core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n
        return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0)
    }

    private func terminateAndCount(_ color: Bool, _ run: Int, _ h: inout [Int]) -> Int {
        var run = run
        if color { addHistory(run, &h); run = 0 }
        run += size
        addHistory(run, &h)
        return countPatterns(h)
    }

    private func addHistory(_ run: Int, _ h: inout [Int]) {
        var run = run
        if h[0] == 0 { run += size } // light border before the first run
        h.removeLast()
        h.insert(run, at: 0)
    }

    // MARK: Tables and Reed-Solomon

    static func numRawDataModules(_ ver: Int) -> Int {
        var result = (16 * ver + 128) * ver + 64
        if ver >= 2 {
            let numAlign = ver / 7 + 2
            result -= (25 * numAlign - 10) * numAlign - 55
            if ver >= 7 { result -= 36 }
        }
        return result
    }

    static func numDataCodewords(_ ver: Int, _ ecc: Ecc) -> Int {
        numRawDataModules(ver) / 8 - eccPerBlock[ecc.rawValue][ver] * numBlocks[ecc.rawValue][ver]
    }

    static func reedSolomonDivisor(_ degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    static func reedSolomonRemainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for b in data {
            let factor = b ^ result.removeFirst()
            result.append(0)
            for i in 0..<divisor.count { result[i] ^= multiply(divisor[i], factor) }
        }
        return result
    }

    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> i) & 1) * Int(x)
        }
        return UInt8(z)
    }

    static let eccPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]
    static let numBlocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]

    // MARK: Segments

    struct Segment {
        enum Mode {
            case numeric, alphanumeric, byte
            var bits: Int { switch self { case .numeric: 1; case .alphanumeric: 2; case .byte: 4 } }
            func charCountBits(_ ver: Int) -> Int {
                let i = (ver + 7) / 17
                switch self {
                case .numeric: return [10, 12, 14][i]
                case .alphanumeric: return [9, 11, 13][i]
                case .byte: return [8, 16, 16][i]
                }
            }
        }
        let mode: Mode
        let numChars: Int
        let data: [Bool]

        static let alphanumericCharset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")

        /// One segment in the densest mode that fits all of `text`, as `QrSegment.makeSegments`.
        static func make(_ text: String) -> [Segment] {
            if text.isEmpty { return [] }
            let chars = Array(text)
            if chars.allSatisfy({ $0.isASCII && $0.isNumber }) {
                var bb: [Bool] = []
                var i = 0
                while i < chars.count {
                    let n = min(chars.count - i, 3)
                    bb.append(bits: Int(String(chars[i..<i + n]))!, count: n * 3 + 1)
                    i += n
                }
                return [Segment(mode: .numeric, numChars: chars.count, data: bb)]
            }
            if chars.allSatisfy({ alphanumericCharset.contains($0) }) {
                var bb: [Bool] = []
                var i = 0
                while i + 2 <= chars.count {
                    bb.append(bits: alphanumericCharset.firstIndex(of: chars[i])! * 45 + alphanumericCharset.firstIndex(of: chars[i + 1])!, count: 11)
                    i += 2
                }
                if i < chars.count { bb.append(bits: alphanumericCharset.firstIndex(of: chars[i])!, count: 6) }
                return [Segment(mode: .alphanumeric, numChars: chars.count, data: bb)]
            }
            let bytes = Array(text.utf8)
            var bb: [Bool] = []
            for b in bytes { bb.append(bits: Int(b), count: 8) }
            return [Segment(mode: .byte, numChars: bytes.count, data: bb)]
        }

        static func totalBits(_ segs: [Segment], _ ver: Int) -> Int? {
            var result = 0
            for s in segs {
                let ccbits = s.mode.charCountBits(ver)
                if s.numChars >= 1 << ccbits { return nil }
                result += 4 + ccbits + s.data.count
            }
            return result
        }
    }
}

extension Array where Element == Bool {
    mutating func append(bits value: Int, count: Int) {
        guard count > 0 else { return }
        for i in stride(from: count - 1, through: 0, by: -1) { append((value >> i) & 1 != 0) }
    }
}
