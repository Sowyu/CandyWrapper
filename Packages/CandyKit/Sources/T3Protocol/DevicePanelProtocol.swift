import Foundation

/// packages/contracts/src/device.ts:56-170. Unknown fields remain forward compatible.
public struct DevicePanelDevice: Codable, Sendable, Equatable {
    public var hostId: String
    public var id: String
    public var platform: String
    public var name: String
    public var version: String
    public var booted: Bool
    public var physical: Bool
    public var key: String { hostId + ":" + id }
}
public struct DevicePanelHost: Codable, Sendable, Equatable {
    public struct Platform: Codable, Sendable, Equatable {
        public var platform: String
        public var available: Bool
        public var reason: String?
    }
    public var id: String
    public var label: String
    public var kind: String
    public var platforms: [Platform]
    public var tools: DevicePanelToolVersions? = nil
    public var toolInspectionError: String? = nil
    public var hubInstalled: Bool? = nil
    public var agentDeviceInstalled: Bool? = nil
}
public struct DevicePanelToolVersion: Codable, Sendable, Equatable {
    public var requiredVersion: String
    public var installedVersions: [String]
    public var runningVersion: String?
    public var displayedVersion: String? {
        runningVersion ?? (installedVersions.contains(requiredVersion) ? requiredVersion : installedVersions.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.last)
    }
}
public struct DevicePanelToolVersions: Codable, Sendable, Equatable {
    public var hub: DevicePanelToolVersion
    public var agent: DevicePanelToolVersion
}
public struct DevicePanelHostStatus: Codable, Sendable, Equatable {
    public var status: String
    public var detail: String?
    public var message: String {
        detail ?? (status == "failed" ? "Device support could not start." : status == "installing" ? "Installing device tools…" : status == "starting" ? "Starting device tools…" : status.capitalized)
    }
}
public struct DevicePanelSession: Codable, Sendable, Equatable {
    public var threadId: String
    public var hostId: String
    public var deviceId: String
    public var platform: String
    public var key: String { hostId + ":" + deviceId }
}
public struct DevicePanelState: Codable, Sendable, Equatable {
    public var hosts: [DevicePanelHost]
    public var hostStatus: String
    public var hostStatusDetail: String?
    public var hostStatuses: [String: DevicePanelHostStatus]? = nil
    public var supportsHostRetry: Bool? = nil
    public var supportsToolUpdate: Bool? = nil
    public var supportsToolInspection: Bool? = nil
    public var devices: [DevicePanelDevice]
    public var sessions: [DevicePanelSession]
    public var onboardingCompleted: Bool
    public var agentAccessEnabled: Bool
    public var hubBasePath: String
    public var revision: Int

    /// DeviceSetup.tsx:28-66. An absent runtime must not be reported as ready.
    public func platformMessage(_ platform: String) -> String {
        let availability = hosts.flatMap(\.platforms).first { $0.platform == platform }
        guard availability?.available == true else {
            return availability?.reason ?? "\(platform == "ios" ? "iOS" : "Android") support was not detected."
        }
        if hostStatus == "ready", !devices.contains(where: { $0.platform == platform }) {
            return platform == "ios"
                ? "Xcode is installed, but no iOS Simulator is available. Install a runtime in Xcode Settings → Components."
                : "The Android SDK is installed, but no virtual device exists. Create one in Android Studio → Device Manager."
        }
        return platform == "ios" ? "Xcode and iOS Simulator are available." : "The Android SDK and Emulator are available."
    }
}

public enum DevicePanelWire {
    /// stream.ts:354-363, DeviceHubProxy.ts:146-155. Host selection stays on the T3 origin.
    public static func url(base: URL, hubPath: String, platform: String, deviceId: String,
                           hostId: String, ticket: String, video: Bool) -> URL? {
        guard hubPath.hasPrefix("/api/device-hub"), !hubPath.contains("..") else { return nil }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let vendor = platform == "ios" ? "/vendor/serve-sim" : "/vendor/serve-emu"
        let segment = deviceId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? ""
        c.percentEncodedPath = hubPath + vendor + (platform == "ios" ? (video ? "/helper/\(segment)/stream.mjpeg" : "/helper/ws") : "/ws")
        if !video || platform == "android" { c.scheme = c.scheme == "https" ? "wss" : "ws" }
        c.queryItems = [URLQueryItem(name: "wsTicket", value: ticket), URLQueryItem(name: "hostId", value: hostId)]
        if !video || platform == "android" { c.queryItems?.append(URLQueryItem(name: "device", value: deviceId)) }
        if platform == "android" { c.queryItems?.append(URLQueryItem(name: "frame-meta", value: "1")) }
        return c.url
    }
    public static func tagged(_ tag: UInt8, _ json: JSONValue) -> Data {
        Data([tag]) + ((try? JSONEncoder().encode(json)) ?? Data())
    }
    public static func touch(platform: String, phase: String, x: Double, y: Double) -> Data {
        let x = max(0, min(1, x)), y = max(0, min(1, y))
        if platform == "ios" { return tagged(3, .object(["type": .string(phase), "x": .number(x), "y": .number(y)])) }
        return (try? JSONEncoder().encode(JSONValue.object(["type": .string("touch"), "action": .string(phase == "begin" ? "down" : phase == "move" ? "move" : "up"), "x": .number(x), "y": .number(y)]))) ?? Data()
    }
}

/// Incremental multipart JPEG extraction. Bounded even when a peer sends malformed data.
public struct DevicePanelJPEGParser: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func push(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while let start = buffer.range(of: Data([0xff, 0xd8])),
              let end = buffer.range(of: Data([0xff, 0xd9]), in: start.upperBound..<buffer.endIndex) {
            frames.append(Data(buffer[start.lowerBound..<end.upperBound]))
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        }
        if buffer.count > 16 * 1024 * 1024 { buffer.removeAll(keepingCapacity: false) }
        return frames
    }
}
