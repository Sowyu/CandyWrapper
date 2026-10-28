import Foundation

/// settings.ts:86-128 (3814). A weekday always means its next occurrence after today.
public enum SnoozePresetSetting: Equatable, Sendable {
    case after(minutes: Int)
    case at(day: String, time: String)

    public static let days = ["today", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    public static let maximumCount = 8
    public static let maximumMinutes = 43_200
    public static let defaults: [Self] = [.after(minutes: 60), .after(minutes: 180), .at(day: "today", time: "18:00"),
                                         .at(day: "tomorrow", time: "09:00"), .at(day: "monday", time: "09:00")]
    public init?(_ json: JSONValue) {
        if json["kind"]?.stringValue == "after", let n = json["minutes"]?.doubleValue,
           n >= 1, n <= Double(Self.maximumMinutes), n.rounded() == n {
            self = .after(minutes: Int(n))
        } else if json["kind"]?.stringValue == "at", let day = json["day"]?.stringValue,
                  Self.days.contains(day), let time = json["time"]?.stringValue,
                  time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil {
            self = .at(day: day, time: time)
        } else { return nil }
    }
    public var json: JSONValue {
        switch self {
        case .after(let minutes): .object(["kind": .string("after"), "minutes": .number(Double(minutes))])
        case .at(let day, let time): .object(["kind": .string("at"), "day": .string(day), "time": .string(time)])
        }
    }
    public var id: String {
        switch self { case .after(let n): "after:\(n)"; case .at(let day, let time): "at:\(day):\(time)" }
    }
    public static func decode(_ value: JSONValue?) -> [Self] {
        guard let array = value?.arrayValue, array.count <= maximumCount else { return defaults }
        let decoded = array.compactMap(Self.init)
        return decoded.count == array.count ? decoded : defaults
    }
}
