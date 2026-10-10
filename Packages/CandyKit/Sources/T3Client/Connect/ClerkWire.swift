import Foundation

// Clerk Frontend API shapes, decoded with snake_case keys like Clerk's own decoder
// (clerk-ios Sources/ClerkKit/Utils/JSONDecoder+Ext.swift). Only the fields CandyWrapper reads.
// Field names follow clerk/openapi-specs fapi/2026-05-12.yml and the clerk-ios models cited per type.
// clerk-ios was read at main d85ac699 (2026-10-09).

/// `GET /v1/environment` (fapi `Client.Environment`; clerk-ios `Domains/Environment/Environment.swift`,
/// `AuthConfig.swift`, `UserSettings.swift`).
public struct ClerkEnvironment: Sendable, Equatable, Decodable {
    public var singleSessionMode: Bool
    /// `auth_config.native_settings.api_enabled`. Clerk's SDK treats a missing block as off
    /// (`AuthConfig.NativeSettings.default`).
    public var nativeAPIEnabled: Bool
    public var emailCodeEnabled: Bool
    public var passwordEnabled: Bool

    public init(singleSessionMode: Bool, nativeAPIEnabled: Bool, emailCodeEnabled: Bool, passwordEnabled: Bool) {
        self.singleSessionMode = singleSessionMode
        self.nativeAPIEnabled = nativeAPIEnabled
        self.emailCodeEnabled = emailCodeEnabled
        self.passwordEnabled = passwordEnabled
    }

    private struct Wire: Decodable {
        struct AuthConfig: Decodable {
            struct Native: Decodable { var apiEnabled: Bool? }
            var singleSessionMode: Bool
            var nativeSettings: Native?
        }
        struct UserSettings: Decodable {
            struct Attribute: Decodable {
                var enabled: Bool?
                var usedForFirstFactor: Bool?
                var firstFactors: [String]?
            }
            var attributes: [String: Attribute]?
        }
        var authConfig: AuthConfig
        var userSettings: UserSettings?
    }

    public init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        singleSessionMode = wire.authConfig.singleSessionMode
        nativeAPIEnabled = wire.authConfig.nativeSettings?.apiEnabled ?? false
        let email = wire.userSettings?.attributes?["email_address"]
        emailCodeEnabled = email?.enabled == true && email?.usedForFirstFactor == true
            && (email?.firstFactors ?? []).contains("email_code")
        passwordEnabled = wire.userSettings?.attributes?["password"]?.enabled == true
    }
}

/// A sign-in attempt (fapi `Client.SignIn`; clerk-ios `Domains/Auth/SignIn/SignIn.swift`).
struct ClerkSignInObject: Decodable, Sendable {
    struct Factor: Decodable, Sendable {
        var strategy: String
        var safeIdentifier: String?
        var emailAddressId: String?
    }
    struct Verification: Decodable, Sendable {
        var status: String?
        var strategy: String?
    }
    var id: String
    /// `complete`, `needs_first_factor`, `needs_second_factor`, `needs_client_trust`, ...
    /// (clerk-ios `SignIn+Status.swift`).
    var status: String
    var identifier: String?
    var supportedFirstFactors: [Factor]?
    var supportedSecondFactors: [Factor]?
    var firstFactorVerification: Verification?
    var secondFactorVerification: Verification?
    var createdSessionId: String?

    /// The factor's `email_address_id` the way clerk-ios picks it: the one whose `safe_identifier`
    /// matches the sign-in identifier, else the first factor with the strategy
    /// (`SignIn.swift` `sendEmailCode`, `identifyingFirstFactor`).
    func emailFactor(_ strategy: String, in factors: [Factor]?, fallbackToFirst: Bool) -> Factor? {
        let matching = factors?.filter { $0.strategy == strategy } ?? []
        if let hit = matching.first(where: { $0.safeIdentifier == identifier }) { return hit }
        return fallbackToFirst ? matching.first : nil
    }
}

/// The device's Clerk client (fapi `Client.Client`; clerk-ios `Domains/Client/Client.swift`).
struct ClerkClientObject: Decodable, Sendable {
    var id: String
    var sessions: [ClerkSessionObject]
    var lastActiveSessionId: String?
}

/// fapi `Client.Session`; clerk-ios `Domains/Auth/Session/Session.swift`.
struct ClerkSessionObject: Decodable, Sendable {
    struct User: Decodable, Sendable {
        var id: String
        var imageUrl: String?
        var firstName: String?
        var lastName: String?
    }
    struct PublicUserData: Decodable, Sendable {
        var identifier: String?
        var userId: String?
        var imageUrl: String?
        var firstName: String?
        var lastName: String?
    }
    var id: String
    var status: String
    var user: User?
    var publicUserData: PublicUserData?

    var userId: String? { user?.id ?? publicUserData?.userId }
}

/// `GET /v1/client`: `{response: Client}` (fapi `Client.ClientWrappedClient`). Some versions put it in `client`.
struct ClerkClientEnvelope: Decodable, Sendable {
    var response: ClerkClientObject?
    var client: ClerkClientObject?
}

/// `{response, client}` (fapi `Client.ClientWrappedSignIn`; clerk-ios `Domains/Client/ClientResponse.swift`).
struct ClerkClientResponse<Response: Decodable & Sendable>: Decodable, Sendable {
    var response: Response
    var client: ClerkClientObject?
}

/// `POST /v1/client/sessions/{id}/tokens/{template}` returns `{jwt}`, or `null`
/// (fapi `createSessionTokenWithTemplate`; clerk-ios `TokenResource.swift`, `SessionAPI.fetchToken`
/// returns `Request<TokenResource?>`).
struct ClerkTokenObject: Decodable, Sendable {
    var jwt: String
}

/// `{errors: [{code, message, long_message, meta}], clerk_trace_id}` (clerk-ios
/// `Domains/Common/ClerkAPIError.swift`; examples in https://clerk.com/docs/guides/development/errors/frontend-api).
struct ClerkErrorBody: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var code: String
        var message: String?
        var longMessage: String?
        var meta: Meta?
    }
    struct Meta: Decodable, Sendable {
        var lockoutExpiresInSeconds: Int?
    }
    var errors: [Item]
}

enum ClerkWire {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// The form encoding Clerk's SDK sends: keys sorted, Alamofire's `afURLQueryAllowed` set
    /// (RFC 3986 query characters minus `:#[]@!$&'()*+,;=`), spaces as `%20`
    /// (clerk-ios `Utils/URLEncodedFormEncoder.swift:247-296,1031-1037`, used by
    /// `ClerkURLEncodedFormEncoderMiddleware.swift`).
    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: ":#[]@!$&'()*+,;="))
        func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let pairs = fields.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

/// The device headers Clerk's SDK sends on every request (clerk-ios
/// `Networking/Middleware/ClerkHeaderRequestMiddleware.swift`, values from `Utils/DeviceHelper.swift`).
/// An AppKit build has no UIKit, so the SDK sends no `x-native-device-id`, type `unspecified` and an
/// empty model; CandyWrapper does the same.
public struct ClerkDeviceInfo: Sendable, Equatable {
    public var deviceType: String
    public var deviceModel: String
    public var osVersion: String
    public var appVersion: String
    public var bundleId: String
    public var isSandbox: String

    public init(deviceType: String = "unspecified", deviceModel: String = "", osVersion: String,
                appVersion: String, bundleId: String, isSandbox: String = "false") {
        self.deviceType = deviceType
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.bundleId = bundleId
        self.isSandbox = isSandbox
    }

    public static var current: ClerkDeviceInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return ClerkDeviceInfo(
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            bundleId: Bundle.main.bundleIdentifier ?? "")
    }
}
