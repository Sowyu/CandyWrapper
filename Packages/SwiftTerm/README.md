# SwiftTerm, vendored

The terminal drawer's emulator and AppKit view. Upstream: https://github.com/migueldeicaza/SwiftTerm,
release `v1.19.0`, commit `464df5207fc2432e16c9a23abe538187196daf5f`, MIT (see `LICENSE`).

## Why vendored instead of a remote package

The remote package does not build here as it is:

- Its target compiles `Apple/Metal/Shaders.metal` as a resource. Xcode 27 ships without the Metal
  toolchain (`xcrun metal` fails: "missing Metal Toolchain"), so `swift build` stops at
  `CompileMetalFile` (tried 2026-10-10 against 1.19.0).
- Its target runs the `SwiftTermBuildInfoPlugin` build plugin, which `xcodebuild` refuses to run
  until someone trusts it in Xcode or passes `-skipPackagePluginValidation`.

CandyWrapper only uses the CoreText renderer, so neither is needed.

## What changed from upstream

- Copied `Sources/SwiftTerm` only. Removed `iOS/`, `Documentation.docc/`, `Mac/README.md` and
  `Apple/Metal/Shaders.metal`. The Metal renderer's Swift files stay; they are never switched on
  (`setUseMetal` is not called), and without the shader library they would fall back anyway.
- `SwiftTermBuildInfo.swift` is written by hand with the release's tag and commit, in place of
  the plugin's generated file.
- `AppleTerminalView.queuePendingDisplay` captures the view weakly so a queued redraw does not
  retain a closed pane and its buffer (2026-10-11 bug sweep).
- `AppleTerminalView` gives Private Use Area characters the base font lacks (Nerd Font icons) an
  isolated cell with the font `CTFontCreateForString` resolves. CoreText's line layout ignores a
  cascade list on the system UI fonts, so they drew as LastResort boxes (2026-10-11, M8).
- `Package.swift` builds the target with `-Osize` in release, like CandyKit.

## Updating

1. Clone the new release tag.
2. Replace `Sources/SwiftTerm` with its `Sources/SwiftTerm`, then remove the same paths as above.
3. Update the tag and commit here, in `Package.swift` and in `SwiftTermBuildInfo.swift`.
4. Run `swift test` in `Packages/CandyKit` and the app build.
