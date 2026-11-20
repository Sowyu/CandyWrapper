import AppKit
import ImageIO
import DesignSystem

/// The image published beside an environment theme (themeBackground.ts, T3 4928). The primary environment mints
/// a signed URL for `environment-theme-background`, the image downloads once per revision, decodes once and
/// shows behind the main panel (`ThemeBackgroundView`). A failed download retries after 1, 2, 4 and 8 seconds,
/// then waits for the next change. Hiding the window drops the image and any download; showing it loads again.
@MainActor
public final class ThemeBackground {
    public static let shared = ThemeBackground()
    /// `RETRY_DELAYS_MS` (themeBackground.ts:13).
    public static let retryDelays: [Double] = [1, 2, 4, 8]
    /// T3's guide caps the file at 16 MB (shared/src/themeCss.ts THEME_GUIDE).
    public nonisolated static let maxBytes = 16 * 1024 * 1024
    /// The longest decoded side, so a 16 MB photo never holds hundreds of MB decoded.
    // ponytail: one fixed cap, size it from the screen if a 6K display shows the image soft
    public nonisolated static let maxPixels = 3840

    /// The image bytes for a theme on an environment, or nil when the mint or download failed.
    public var fetch: ((_ environmentId: String, _ themeId: String) async -> Data?)?
    public var sleep: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    public var onChange: ((CGImage?) -> Void)?

    public private(set) var image: CGImage? { didSet { if image !== oldValue { onChange?(image) } } }
    private(set) var shownKey: [String]?
    private var loading: Task<Void, Never>?
    private var wanted: (environmentId: String?, themeId: String?, revision: String?) = (nil, nil, nil)
    public private(set) var visible = true

    public init() {}

    /// `applyThemeBackground` (:57-108): shows the image for this theme's revision, or clears it.
    public func apply(environmentId: String?, themeId: String?, revision: String?) {
        wanted = (environmentId, themeId, revision)
        let key: [String]? = { guard visible, let environmentId, let themeId, let revision else { return nil }; return [environmentId, themeId, revision] }()
        guard key != shownKey else { return }
        shownKey = key
        loading?.cancel()
        loading = nil
        // The previous image must not show under the next theme while it loads.
        image = nil
        guard let key, let fetch else { return }
        loading = Task { [weak self] in
            for attempt in 0...Self.retryDelays.count {
                if attempt > 0 {
                    await self?.sleep(Self.retryDelays[attempt - 1])
                }
                guard !Task.isCancelled, let self else { return }
                let data = await fetch(key[0], key[1])
                // Decoded off the main thread, once.
                let decoded = await Task.detached { data.flatMap(Self.decode) }.value
                guard !Task.isCancelled, self.shownKey == key else { return }
                if let decoded { self.image = decoded; self.loading = nil; return }
            }
            // Lets the next change try again.
            self?.loading = nil
            self?.shownKey = nil
        }
    }

    /// The window hid or came back. Hidden, the image and any download are dropped.
    public func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        apply(environmentId: wanted.environmentId, themeId: wanted.themeId, revision: wanted.revision)
    }

    /// `image.type.startsWith("image/")` (:51): anything ImageIO can't read as an image is refused. Decodes now,
    /// at most `maxPixels` on the long side.
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard data.count <= maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png", "org.webmproject.webp", "public.webp"].contains(type)
        else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
