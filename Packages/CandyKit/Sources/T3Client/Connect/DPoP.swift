import CryptoKit
import Foundation

// DPoP proofs in T3's exact format (protocol.md 10.5).
// Source: packages/shared/src/dpop.ts, dpopCommon.ts, apps/mobile/src/features/cloud/dpop.ts:246-302.

/// Unpadded base64url, RFC 4648 section 5 (effect/encoding/Base64Url).
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

/// The public half of the proof key: exactly `{kty, crv, x, y}` and never `d` (dpopCommon.ts:3-8).
public struct DPoPPublicJWK: Codable, Sendable, Equatable {
    public var kty = "EC"
    public var crv = "P-256"
    public var x: String
    public var y: String

    public init(x: String, y: String) {
        self.x = x
        self.y = y
    }

    /// From an uncompressed point `04 || x || y` (mobile dpop.ts:147-158).
    public init(x963 point: Data) throws {
        guard point.count == 65, point.first == 0x04 else { throw DPoPError.invalidKey }
        let bytes = [UInt8](point)
        self.init(x: Base64URL.encode(Data(bytes[1..<33])), y: Base64URL.encode(Data(bytes[33..<65])))
    }

    /// RFC 7638 thumbprint: base64url(SHA-256('{"crv":"P-256","kty":"EC","x":"..","y":".."}')),
    /// members in lexicographic order, no whitespace (dpop.ts:83-94).
    public var thumbprint: String {
        let input = #"{"crv":"\#(crv)","kty":"\#(kty)","x":"\#(x)","y":"\#(y)"}"#
        return Base64URL.encode(Data(SHA256.hash(data: Data(input.utf8))))
    }

    /// Header member order as T3 encodes it: kty, crv, x, y.
    var headerJSON: String {
        #"{"kty":"\#(kty)","crv":"\#(crv)","x":"\#(x)","y":"\#(y)"}"#
    }
}

public enum DPoPError: Error, Sendable, Equatable {
    case invalidKey
    case invalidURL(String)
}

/// A P-256 key that signs proofs. Implementations return ES256 signatures in raw `r || s` form
/// (64 bytes, IEEE P1363), never DER (dpop.ts:163-176).
public protocol DPoPSigningKey: Sendable {
    var publicJWK: DPoPPublicJWK { get }
    /// ES256 over `data`: SHA-256, then ECDSA P-256. Raw 64-byte signature.
    func sign(_ data: Data) throws -> Data
}

extension DPoPSigningKey {
    public var thumbprint: String { publicJWK.thumbprint }
}

/// A key held in memory. Tests use it; `DPoPKeyStore` falls back to it without a Secure Enclave.
public struct SoftwareDPoPKey: DPoPSigningKey {
    let key: P256.Signing.PrivateKey
    public let publicJWK: DPoPPublicJWK

    public init(_ key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) throws {
        self.key = key
        publicJWK = try DPoPPublicJWK(x963: key.publicKey.x963Representation)
    }

    public func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).rawRepresentation
    }
}

/// A Secure Enclave key. The private scalar never leaves the enclave; `dataRepresentation` is a
/// blob only this Mac's enclave can use.
public struct SecureEnclaveDPoPKey: DPoPSigningKey, @unchecked Sendable {
    // Immutable after init; CryptoKit's enclave key type is not marked Sendable.
    let key: SecureEnclave.P256.Signing.PrivateKey
    public let publicJWK: DPoPPublicJWK

    public init(_ key: SecureEnclave.P256.Signing.PrivateKey) throws {
        self.key = key
        publicJWK = try DPoPPublicJWK(x963: key.publicKey.x963Representation)
    }

    public func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).rawRepresentation
    }
}

public enum DPoP {
    public static let typ = "dpop+jwt"
    public static let alg = "ES256"

    /// `htu`: the URL without query and fragment, WHATWG-serialized: lower-case scheme and host,
    /// default port dropped, empty path as `/` (dpopCommon.ts:11-20). The verifier compares it by
    /// exact string equality, so sign the scheme and authority the request really goes to.
    public static func htu(_ url: URL) throws -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = c.scheme?.lowercased(), let host = c.percentEncodedHost, !host.isEmpty
        else { throw DPoPError.invalidURL(url.absoluteString) }
        c.query = nil
        c.fragment = nil
        let defaultPort = ["http": 80, "https": 443, "ws": 80, "wss": 443][scheme]
        let port = c.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        let path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(bracketed.lowercased())\(port)\(path)"
    }

    /// `ath`: base64url(SHA-256(ASCII access token)) (dpop.ts:96-98).
    public static func accessTokenHash(_ accessToken: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(accessToken.utf8))))
    }

    /// A compact JWS proof for one request. Pass `accessToken` whenever the request carries one
    /// (`Authorization: DPoP <token>`); omit it on `/oauth/token` and `/v1/client/dpop-token`.
    /// Every call gets a fresh `jti`: the environment and the relay reject a reused one.
    /// T3 has no nonce (no `DPoP-Nonce` anywhere in apps, packages or infra).
    public static func proof(method: String, url: URL, accessToken: String? = nil, key: any DPoPSigningKey,
                             now: Date = Date(), jti: String = UUID().uuidString.lowercased()) throws -> String {
        let header = #"{"typ":"\#(typ)","alg":"\#(alg)","jwk":\#(key.publicJWK.headerJSON)}"#
        var payload = #"{"htm":\#(jsonString(method.uppercased())),"htu":\#(jsonString(try htu(url))),"#
            + #""jti":\#(jsonString(jti)),"iat":\#(Int(now.timeIntervalSince1970.rounded(.down)))"#
        if let accessToken { payload += #","ath":"\#(accessTokenHash(accessToken))""# }
        payload += "}"
        let signingInput = Base64URL.encode(Data(header.utf8)) + "." + Base64URL.encode(Data(payload.utf8))
        let signature = try key.sign(Data(signingInput.utf8))
        return signingInput + "." + Base64URL.encode(signature)
    }

    /// JSON string literal as `JSON.stringify` writes it (`/` stays literal).
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
