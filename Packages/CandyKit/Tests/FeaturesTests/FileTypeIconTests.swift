import Testing
@testable import Features

/// T3's own icons from pierre-icons.ts at 5258 (#42493) win over the built-in set.
@Suite struct FileTypeIconTests {
    @Test func t3IconsWinOverTheBuiltInSet() {
        #expect(FileTypeIcon.token(for: "src/app.test.ts") == "t3-file-icon-typescript-test")
        #expect(FileTypeIcon.token(for: "src/app.spec.jsx") == "t3-file-icon-javascript-test")
        #expect(FileTypeIcon.token(for: "src/app.ts") == "typescript")
        #expect(FileTypeIcon.token(for: "vitest.config.ts") == "t3-file-icon-vitest")
        #expect(FileTypeIcon.token(for: "pnpm-lock.yaml") == "t3-file-icon-pnpm")
        #expect(FileTypeIcon.token(for: "App/Main.kt") == "t3-file-icon-kotlin")
        #expect(FileTypeIcon.token(for: ".oxlintrc.jsonc") == "oxc")
        #expect(FileTypeIcon.token(for: "photo.HEIC") == "image")
        // The stroked and 24px T3 icons, with one color each.
        #expect(FileTypeIcon.token(for: "src/Main.java") == "t3-file-icon-java")
        #expect(FileTypeIcon.token(for: "Cargo.toml") == "t3-file-icon-toml")
        #expect(FileTypeIcon.token(for: "clip.mp4") == "t3-file-icon-video")
        #expect(FileTypeIcon.token(for: "report.pdf") == "t3-file-icon-pdf")
        #expect(FileIcons.colors["t3-file-icon-pdf"]! == (0xd52c36, 0xff6762))
        #expect(FileIcons.symbols["t3-file-icon-video"]!.elements.allSatisfy { $0.paint.stroke == .current && $0.paint.fill == .none })
        for token in Set(FileIcons.byFileName.values).union(FileIcons.byExtension.values).union(FileIcons.completeOverrides.values) {
            #expect(FileIcons.symbols[token] != nil, "no symbol for \(token)")
        }
    }
}
