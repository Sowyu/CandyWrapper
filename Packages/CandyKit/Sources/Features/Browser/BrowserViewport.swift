import Foundation
import T3Protocol

/// Browser viewport math for the device toolbar: packages/shared/src/previewViewport.ts,
/// apps/web/src/browser/browserViewportLayout.ts and browserDefaults.ts:122-144. Settings are the
/// wire's `PreviewViewportSetting` (`fill`, `freeform` or `preset` with a size).
public enum BrowserViewport {
    public static let minDimension = 240, maxDimension = 3840, maxArea = 3840 * 2160
    /// `BROWSER_DEVICE_TOOLBAR_HEIGHT`, `BROWSER_VIEWPORT_RESIZE_RAIL_SIZE`.
    public static let toolbarHeight: CGFloat = 38, railSize: CGFloat = 10

    public struct Size: Equatable, Sendable { public var width: Int; public var height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height } }

    public static let fill: JSONValue = .object(["_tag": .string("fill")])

    public static func freeform(_ s: Size) -> JSONValue {
        .object(["_tag": .string("freeform"), "width": .number(Double(s.width)), "height": .number(Double(s.height))])
    }

    /// `resolvePreviewViewport({mode: "preset"})`: the preset at its native orientation.
    public static func preset(_ id: String) -> JSONValue? {
        guard let p = SettingsBrowserViewport.presets.first(where: { $0.id == id }) else { return nil }
        return .object(["_tag": .string("preset"), "presetId": .string(id), "width": .number(Double(p.width)), "height": .number(Double(p.height))])
    }

    public static func isFill(_ setting: JSONValue?) -> Bool { (setting?["_tag"]?.stringValue ?? "fill") == "fill" }

    public static func size(_ setting: JSONValue) -> Size? {
        guard !isFill(setting), let w = setting["width"]?.intValue, let h = setting["height"]?.intValue else { return nil }
        return Size(width: w, height: h)
    }

    /// The select's value: a known preset's id, else "responsive".
    public static func selectedPreset(_ setting: JSONValue) -> String? {
        guard setting["_tag"]?.stringValue == "preset", let id = setting["presetId"]?.stringValue,
              SettingsBrowserViewport.presets.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// `customValid` (BrowserDeviceToolbar.tsx:67-75).
    public static func isValid(width: Int?, height: Int?) -> Bool {
        guard let width, let height else { return false }
        return (minDimension...maxDimension).contains(width) && (minDimension...maxDimension).contains(height) && width * height <= maxArea
    }

    static func clamp(_ v: Int) -> Int { min(maxDimension, max(minDimension, v)) }

    /// `resizeAtAspectRatio` (browserViewportLayout.ts:145-194).
    static func resizeAtAspectRatio(_ desired: Double, _ ratio: Double, widthPrimary: Bool) -> Size {
        let lo = Double(minDimension), hi = Double(maxDimension), area = Double(maxArea)
        if widthPrimary {
            let minimum = Int(max(lo, lo * ratio).rounded(.up))
            let maximum = Int(min(hi, hi * ratio, (area * ratio).squareRoot()).rounded(.down))
            var width = min(maximum, max(minimum, Int(desired.rounded())))
            var height = Int((Double(width) / ratio).rounded())
            while width * height > maxArea && width > minimum { width -= 1; height = Int((Double(width) / ratio).rounded()) }
            return Size(width: width, height: height)
        }
        let minimum = Int(max(lo, lo / ratio).rounded(.up))
        let maximum = Int(min(hi, hi / ratio, (area / ratio).squareRoot()).rounded(.down))
        var height = min(maximum, max(minimum, Int(desired.rounded())))
        var width = Int((Double(height) * ratio).rounded())
        while width * height > maxArea && height > minimum { height -= 1; width = Int((Double(height) * ratio).rounded()) }
        return Size(width: width, height: height)
    }

    /// `resizeFreeformViewport` (browserViewportLayout.ts:196-247) for the toolbar's east and south edits
    /// and the zero-delta fit. JS `Math.round` rounds halves up.
    public static func resize(_ start: (width: Double, height: Double), dx: Double, dy: Double, zoom: Double = 1,
                              east: Bool = false, south: Bool = false, aspectRatio: Double? = nil) -> Size {
        let z = zoom.isFinite && zoom > 0 ? zoom : 1
        let desiredW = start.width + dx / z, desiredH = start.height + dy / z
        func round(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }
        if let r = aspectRatio, r.isFinite, r > 0 {
            let controlsW = dx != 0 || east, controlsH = dy != 0 || south
            let widthPrimary = controlsW && !controlsH ? true : controlsH && !controlsW ? false
                : abs(desiredW - start.width) / start.width >= abs(desiredH - start.height) / start.height
            return resizeAtAspectRatio(widthPrimary ? desiredW : desiredH, r, widthPrimary: widthPrimary)
        }
        var w = clamp(round(desiredW)), h = clamp(round(desiredH))
        if w * h <= maxArea { return Size(width: w, height: h) }
        if abs(dx) >= abs(dy) { w = max(minDimension, maxArea / h) } else { h = max(minDimension, maxArea / w) }
        return Size(width: w, height: h)
    }

    /// `browserResponsiveViewportForToggle`: a non-fill default from Settings wins, else the panel's device area
    /// (`resolveResponsiveBrowserViewportSize`), else 1024 by 768.
    public static func toggleOn(defaultViewport: JSONValue?, panel: CGSize?, zoom: Double) -> JSONValue {
        if let d = defaultViewport, !isFill(d), size(d) != nil { return d }
        guard let panel, panel.width > 0, panel.height > 0 else { return freeform(Size(width: 1024, height: 768)) }
        let z = zoom.isFinite && zoom > 0 ? zoom : 1
        let area = (width: max(1, Double(panel.width) - Double(railSize) * 2) / z,
                    height: max(1, Double(panel.height) - Double(toolbarHeight) - Double(railSize)) / z)
        return freeform(resize(area, dx: 0, dy: 0))
    }
}
