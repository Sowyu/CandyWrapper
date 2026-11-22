import AppKit
import Testing
@testable import Features

/// Typing is the composer's hot path, and showing Markdown markers (#30421) rewrites the text on selection changes.
/// This times a keystroke and a caret move in a 5,000-character draft with styled words, and prints the numbers.
@MainActor struct ComposerMarkdownSourceBenchmarkTests {
    private static let draft: String = {
        let line = "Some **bold** words and `code` here, then *it* and plain text to fill the line.\n"
        var text = ""
        while (text as NSString).length < 5_000 { text += line }
        return text
    }()

    private func host() -> (NSWindow, ComposerEditor) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ComposerEditor()
        editor.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        editor.chipLook = ComposerChipLook.basic
        editor.richTextEnabled = true
        window.contentView = editor
        window.makeFirstResponder(editor)
        editor.setText(Self.draft)
        return (window, editor)
    }

    private func median(_ samples: [Duration]) -> Double {
        let sorted = samples.sorted()
        let d = sorted[sorted.count / 2].components
        return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
    }

    @Test func keystrokeAndSelectionCost() {
        let (window, editor) = host()
        _ = window
        let clock = ContinuousClock()
        let text = editor.string as NSString
        let bold = text.range(of: "bold").location + 2
        let plain = text.range(of: "fill").location
        // Keystrokes in plain text far from styled words, then right after a styled word.
        var plainKeys: [Duration] = [], styledKeys: [Duration] = [], moves: [Duration] = [], plainMoves: [Duration] = []
        for round in 0..<60 {
            editor.setSelectedRange(NSRange(location: plain, length: 0))
            let t = clock.measure { editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) }
            if round >= 10 { plainKeys.append(t) }
            editor.setSelectedRange(NSRange(location: bold, length: 0))
            let k = clock.measure { editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0)) }
            if round >= 10 { styledKeys.append(k) }
        }
        for round in 0..<60 {
            let to = (editor.string as NSString).range(of: "bold").location + 2
            let m = clock.measure { editor.setSelectedRange(NSRange(location: to, length: 0)) }
            let p = clock.measure { editor.setSelectedRange(NSRange(location: plain, length: 0)) }
            let q = clock.measure { editor.setSelectedRange(NSRange(location: plain + 1, length: 0)) }
            if round >= 10 { moves.append(m); moves.append(p); plainMoves.append(q) }
        }
        // CW_BENCH_PROFILE=typing types in plain text for about 15 s, for `sample`.
        if ProcessInfo.processInfo.environment["CW_BENCH_PROFILE"] == "typing" {
            try? "\(getpid())".write(toFile: "/tmp/cw-bench-profile.pid", atomically: true, encoding: .utf8)
            let until = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < until {
                editor.setSelectedRange(NSRange(location: plain, length: 0))
                editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        print(String(format: "BENCH keystroke plain=%.3fms styled=%.3fms selection into/out of styled=%.3fms plain=%.3fms",
                     median(plainKeys), median(styledKeys), median(moves), median(plainMoves)))
        #expect(median(plainKeys) < 50)
    }
}
