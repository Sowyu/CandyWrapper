# CandyWrapper

CandyWrapper is a native macOS client for [T3 Code](https://github.com/pingdotgg/t3code). It talks to the official T3 server and T3 Connect with the same protocol as the official app and looks like T3 Code Nightly. It is written in Swift and AppKit with no Electron, and it opens a web view only where T3 itself shows web content, such as the built-in browser or an HTML preview. It is an unofficial project and is not affiliated with or endorsed by T3 Tools Inc., the makers of T3 Code.

![A thread in CandyWrapper, dark theme: tool calls, a markdown reply with a table and a code block, and the changed files card](docs/readme/thread-dark.png)

## Numbers

- 12x less CPU in the app while a turn streams.
- 91% less memory with a thread open and idle, 41 MB against 469 MB.
- Over 2,000x fewer wakeups a second when idle.
- 5x less energy while a turn streams.
- 11x smaller download, 14.6 MB against 162 MB.

### CandyWrapper vs the T3 Code desktop app

Both apps ran one after the other on the same Mac mini M4 against the same T3 server data on 2026-10-11: the official app at 0.0.46-nightly.20261009.2861 and CandyWrapper at commit 0209d52, Release build. App numbers count only the app's own processes, which for the official app means its Electron main, GPU, renderer and network processes. Both clients use the same T3 server, so the server costs the same either way and is not in these numbers.

| What was measured | T3 Code desktop | CandyWrapper | Difference |
|---|---|---|---|
| CPU while one Claude Haiku turn streams, mean of two turns | 15.5% | 1.26% | 12x less, 91% lower |
| Energy Impact while a turn streams, mean of two turns | 85.1 | 15.1 | 5x less, 82% lower |
| Memory with a small thread open, idle | 469 MB | 41.3 MB | 11x less, 91% lower |
| Memory with a 2,000-message thread open, 50 threads in the sidebar | 500 MB | 71 MB | 7x less, 85% lower |
| Idle CPU, window open, no turn running | 2.04% | 0.00% | more than 400x less, 99% lower |
| Idle interrupt wakeups a second | 74.5 | 0.03 | over 2,000x fewer, 99.9% fewer |
| Launch to a sidebar with data | 3.71 s | 0.20 s | 18x faster, 94% less time, see note 1 |
| Frames over 16.7 ms while scrolling 2,000 messages at 60 Hz | 1 of 912 | 0 of 1,095 | |
| Keypress to glyph on screen, median | 37.8 ms | 37.8 ms | tie |
| Download, v0.1.7 DMG against the official DMG | 162.2 MB | 14.6 MB | 11x smaller, 90% smaller, see note 2 |
| App on disk | 366 MB | 27 MB | 13x smaller, 92% smaller, see note 2 |

1. The official app's time includes starting its bundled server. CandyWrapper's server was already running. The first launch of a freshly built CandyWrapper took 0.71 s.
2. Measured on 2026-10-12. The DMG sizes are the file sizes of `CandyWrapper-0.1.7-arm64.dmg` from this repo's releases and the official `T3-Code-arm64.dmg` for 0.0.46-nightly.20261009.2861. The app sizes come from `du -sk` on each app inside its mounted DMG, with 1 MB as 1,048,576 bytes.

Each ratio and percentage comes from the two measured values, rounded down. An idle CPU of 0.00% means under 0.005%, so the idle ratio uses that bound. [docs/benchmarks.md](docs/benchmarks.md) has the method, the raw numbers and the caveats, and [docs/perf/](docs/perf/) has the per-commit perf reviews of CandyWrapper on its own.

## Screenshots

![The diff panel beside a thread, light theme](docs/readme/diff-light.png)

![The command palette searching threads, dark theme](docs/readme/command-palette-dark.png)

![Settings, General page, light theme](docs/readme/settings-light.png)

## Install

1. Download the DMG from [GitHub Releases](https://github.com/Sowyu/CandyWrapper/releases) and drag CandyWrapper to Applications. It needs macOS 14 or later on Apple silicon.
2. Open CandyWrapper once. macOS says it could not verify that the app is free of malware. Click Done.
3. Open System Settings, click Privacy & Security, scroll to Security and click Open Anyway next to CandyWrapper. The button stays there for about an hour after the blocked open.
4. Enter your login password, then click Open Anyway in the dialog that follows.

Releases are signed with an Apple Development certificate and are not notarized, which is why Gatekeeper asks. Since macOS 15, Control-clicking the app and choosing Open no longer skips this check, so use System Settings. You only do this once. After that, updates arrive inside the app from this repo's signed update feed.

## Connecting

CandyWrapper joins the T3 server already running on your Mac, or starts its own from the installed T3 runtime and stops it when idle. To use a T3 server on another machine, open Settings, then Connections, then Add environment, and paste its pairing link or enter the host and pairing code. Click Sign in to T3 Connect at the bottom of Settings to reach the environments on your T3 Connect account.

## Building from source

The repo includes the generated Xcode project. If you change `project.yml`, regenerate it with [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 first.

```sh
xcodegen generate
xcodebuild -project CandyWrapper.xcodeproj -scheme CandyWrapper -configuration Release build
```

It builds with Xcode 27 and Swift 6. The tests run from the package with `cd Packages/CandyKit && swift test`.

## License

MIT, see [LICENSE](LICENSE). CandyWrapper exists because of [T3 Code](https://github.com/pingdotgg/t3code) by T3 Tools Inc., also MIT licensed. Its protocol, design and behavior come from reading that source.
