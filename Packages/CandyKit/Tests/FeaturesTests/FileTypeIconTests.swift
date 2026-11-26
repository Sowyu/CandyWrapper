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
        for token in Set(FileIcons.byFileName.values).union(FileIcons.byExtension.values).union(FileIcons.completeOverrides.values) {
            #expect(FileIcons.symbols[token] != nil, "no symbol for \(token)")
        }
    }
}
