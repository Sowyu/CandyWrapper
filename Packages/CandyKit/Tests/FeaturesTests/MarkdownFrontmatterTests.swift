import Foundation
import Testing
@testable import Features

/// markdownFrontmatter.test.ts at 3814.
struct MarkdownFrontmatterTests {
    @Test func blanksLeadingFrontmatterWithoutMovingOffsets() {
        let markdown = "---\r\nname: skill\r\n---\r\n# Skill\n- [ ] item\n"
        let masked = MarkdownFrontmatter.mask(markdown)
        #expect(masked == "   \r\n           \r\n   \r\n# Skill\n- [ ] item\n")
        #expect((masked as NSString).range(of: "[ ]").location == (markdown as NSString).range(of: "[ ]").location)
    }

    @Test func handlesByteOrderMarkCarriageReturnsAndDotsFence() {
        #expect(MarkdownFrontmatter.mask("\u{FEFF}---\na: 1\n---\n# Body") == "    \n    \n   \n# Body")
        #expect(MarkdownFrontmatter.mask("---\ra: 1\r...\r# Body") == "   \r    \r   \r# Body")
        #expect(MarkdownFrontmatter.mask("---\n---\n# Body") == "   \n   \n# Body")
    }

    @Test func leavesUnterminatedOrLaterFencesAlone() {
        #expect(MarkdownFrontmatter.mask("---\na: 1\n") == "---\na: 1\n")
        #expect(MarkdownFrontmatter.mask("# A\n---\nb\n---\n") == "# A\n---\nb\n---\n")
        #expect(MarkdownFrontmatter.mask("---\na: 1\n----\n") == "---\na: 1\n----\n")
    }
}
