import Foundation

/// The recovery key: K's 32 bytes as 52 RFC 4648 base32 characters in groups of four (docs/space.md,
/// "Setting up and adding devices"). The last character carries one key bit and four zero bits, so most
/// typos there are caught here; any other typo fails `SpaceKeys.verifyCheck`.
public enum RecoveryKey {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
    static let length = 52

    public static func encode(_ key: SpaceKey) -> String {
        var chars: [UInt8] = []
        chars.reserveCapacity(length + length / 4)
        var buffer: UInt32 = 0
        var bits = 0
        key.withUnsafeBytes { bytes in
            for byte in bytes {
                buffer = (buffer << 8) | UInt32(byte)
                bits += 8
                while bits >= 5 {
                    bits -= 5
                    chars.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
                }
            }
        }
        chars.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
        buffer = 0
        var grouped: [UInt8] = []
        for (i, c) in chars.enumerated() {
            if i > 0, i % 4 == 0 { grouped.append(UInt8(ascii: " ")) }
            grouped.append(c)
        }
        chars.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        return String(decoding: grouped, as: UTF8.self)
    }

    /// Accepts lowercase, spaces and hyphens, as people type or paste it.
    public static func decode(_ text: String) throws -> SpaceKey {
        var values: [UInt8] = []
        values.reserveCapacity(length)
        for c in text.utf8 where c != UInt8(ascii: " ") && c != UInt8(ascii: "-") && c != UInt8(ascii: "\n") {
            let upper = (97...122).contains(c) ? c - 32 : c
            guard let value = alphabet.firstIndex(of: upper) else { throw SpaceCryptoError.recoveryKeyCharacter }
            values.append(UInt8(value))
        }
        guard values.count == length else { throw SpaceCryptoError.recoveryKeyLength }
        var bytes = [UInt8](repeating: 0, count: SpaceKey.byteCount)
        defer {
            bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            values.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        }
        var buffer: UInt32 = 0
        var bits = 0
        var out = 0
        for value in values {
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8, out < bytes.count {
                bits -= 8
                bytes[out] = UInt8(truncatingIfNeeded: buffer >> UInt32(bits))
                out += 1
            }
        }
        guard buffer & ((1 << UInt32(bits)) - 1) == 0 else { throw SpaceCryptoError.recoveryKeyTypo }
        return try SpaceKey(rawBytes: bytes)
    }
}
