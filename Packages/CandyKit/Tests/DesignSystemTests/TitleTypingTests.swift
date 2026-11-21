import Testing
@testable import DesignSystem

/// Rewrite title's typing effect: erase, blink, type, the cap, the way back after a failure, and an outside change.
struct TitleTypingTests {
    typealias T = TitleTyping

    @Test func erasesRightToLeftInAFifteenthOfASecondThenBlinks() {
        let thinking = T.Phase.thinking(old: "Sourdough starter")
        #expect(T.frame(thinking, elapsed: 0) == .init("Sourdough starter", .on))
        let mid = T.frame(thinking, elapsed: T.eraseDuration / 2).text
        #expect(mid.count < 17 && mid.count > 0 && "Sourdough starter".hasPrefix(mid))
        #expect(T.frame(thinking, elapsed: T.eraseDuration) == .init("", .on))
        #expect(T.frame(thinking, elapsed: T.eraseDuration + 0.6) == .init("", .off))
        #expect(T.frame(thinking, elapsed: T.eraseDuration + 1.1) == .init("", .on))
        #expect(!T.isDone(thinking, elapsed: 60), "thinking lasts until the title lands")
    }

    @Test func typesLeftToRightAtTwentyFiveMillisecondsACharacter() {
        let landing = T.Phase.landing(old: "Old", target: "Bread notes", id: 1)
        #expect(T.frame(landing, elapsed: 0) == .init("", .on))
        #expect(T.frame(landing, elapsed: 0.026) == .init("B", .on))
        #expect(T.frame(landing, elapsed: 0.126) == .init("Bread", .on))
        // Typed, then two blinks (off, on, off, on), then the cursor goes and the title rests.
        let typed = 0.025 * 11
        #expect(T.frame(landing, elapsed: typed + 0.01) == .init("Bread notes", .off))
        #expect(T.frame(landing, elapsed: typed + T.tailHalf + 0.01) == .init("Bread notes", .on))
        #expect(T.frame(landing, elapsed: T.landingDuration("Bread notes")) == .init("Bread notes", .hidden))
        #expect(T.isDone(landing, elapsed: T.landingDuration("Bread notes")))
    }

    @Test func aLongTitleStillTypesInPointEightSeconds() {
        let long = String(repeating: "word ", count: 30) // 150 characters
        let landing = T.Phase.landing(old: "x", target: long, id: 2)
        #expect(T.frame(landing, elapsed: 0.401).text.count == 75)
        #expect(T.frame(landing, elapsed: T.typeCap + 0.001).text == long)
        #expect(T.landingDuration(long) <= T.typeCap + Double(T.tailBlinks * 2) * T.tailHalf + 0.0001)
    }

    @Test func aFailureTypesTheOldTitleBack() {
        let back = T.Phase.landing(old: "Sourdough starter", target: "Sourdough starter", id: 3)
        #expect(T.frame(back, elapsed: 0.051).text == "So")
        #expect(T.frame(back, elapsed: 5).text == "Sourdough starter")
    }

    @Test func anOutsideChangeInterrupts() {
        #expect(!T.isInterrupted(.thinking(old: "A"), by: "A"))
        #expect(T.isInterrupted(.thinking(old: "A"), by: "Renamed by hand"))
        let landing = T.Phase.landing(old: "A", target: "B", id: 4)
        #expect(!T.isInterrupted(landing, by: "A"), "the server's rename can arrive after the typing starts")
        #expect(!T.isInterrupted(landing, by: "B"))
        #expect(T.isInterrupted(landing, by: "C"))
    }

    @Test func reduceMotionSwapsWithAStillCursor() {
        #expect(T.frame(.thinking(old: "A"), elapsed: 0, reduced: true) == .init("", .on))
        #expect(T.frame(.thinking(old: "A"), elapsed: 2.6, reduced: true) == .init("", .on))
        let landing = T.Phase.landing(old: "A", target: "B", id: 5)
        #expect(T.frame(landing, elapsed: 0, reduced: true) == .init("B", .hidden))
        #expect(T.isDone(landing, elapsed: 0, reduced: true))
    }
}
