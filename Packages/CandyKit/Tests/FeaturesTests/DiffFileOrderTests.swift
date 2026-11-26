import Testing
@testable import Features

/// Cases from 5258 packages/client-runtime/src/diffFileOrder.test.ts.
@Suite struct DiffFileOrderTests {
    private func order(_ files: [(String, [String])]) -> [String] {
        orderDiffFilesForReview(files.map(\.0)) { files[$0].1 }.map { files[$0].0 }
    }
    private func order(_ paths: [String]) -> [String] { order(paths.map { ($0, []) }) }

    @Test func sourceBeforeTestsAndGenerated() {
        let source = ["src/app.ts", "src/dist.ts", "src/testing.ts"]
        let tests = ["src/__tests__/app.ts", "src/app.spec.tsx", "src/app.test.ts", "test/app.ts", "tests/helpers/app.ts"]
        let generated = ["apps/web/package-lock.json", "dist/app.js", "packages/core/vendor/lib.js", "pnpm-lock.yaml",
                         "public/app.min.js", "src/__snapshots__/app.ts", "src/api.generated.ts", "src/app.test.ts.snap"]
        #expect(order((generated + tests + source).reversed()) == source + tests.prefix(3)
            + ["src/__snapshots__/app.ts", "src/api.generated.ts", "src/app.test.ts.snap"] + tests.suffix(2) + generated.prefix(5))
    }

    @Test func keepsBothEntriesOfATypeChange() {
        let paths = ["CLAUDE.md", "AGENTS.md", "AGENTS.md"]
        #expect(orderDiffFilesForReview(paths) { _ in [] } == [1, 2, 0])
    }

    @Test func testListedLastJoinsItsDirectory() {
        #expect(order(["server/device/Host.ts", "web/settings.ts", "server/ws.ts", "server/device/Host.test.ts", "web/settings.test.ts"])
            == ["server/device/Host.ts", "server/device/Host.test.ts", "server/ws.ts", "web/settings.ts", "web/settings.test.ts"])
    }

    @Test func resolvesImports() {
        #expect(order([("src/ui/a.ts", [#"import { b } from "../lib/b";"#]), ("src/lib/b.ts", [])]) == ["src/lib/b.ts", "src/ui/a.ts"])
        #expect(order([("src/a.ts", [#"import { b } from "./lib";"#]), ("src/lib/index.ts", [])]) == ["src/lib/index.ts", "src/a.ts"])
        #expect(order([("a.mts", [#"import { z } from "./z.mjs";"#]), ("z.mts", [])]) == ["z.mts", "a.mts"])
        #expect(order([("a.ts", [#"import { z } from "./z";"#]), ("z.cts", [])]) == ["z.cts", "a.ts"])
        #expect(order([("src/a.ts", [#"import { b } from "~/lib/b";"#]), ("lib/b.ts", [])]) == ["lib/b.ts", "src/a.ts"])
        #expect(order([("src/a.ts", [#"import { b } from "~/z/b.logic";"#]), ("z/b.logic.ts", []), ("other/b.ts", [])])
            == ["other/b.ts", "z/b.logic.ts", "src/a.ts"])
        #expect(order([("src/a.ts", [#"import { b } from "~/somewhere/b";"#]), ("one/b.ts", []), ("two/b.ts", [])])
            == ["one/b.ts", "src/a.ts", "two/b.ts"])
        #expect(order([("src/a.ts", [#"import { b } from "./b.js";"#]), ("src/b.ts", [])]) == ["src/b.ts", "src/a.ts"])
        #expect(order([("src/a.js", [#"import Worker from "./z.js?worker";"#]), ("src/z.js", [])]) == ["src/z.js", "src/a.js"])
        #expect(order([("src/a.ts", [##"import { z } from "#internal/z";"##]), ("src/z.ts", [])]) == ["src/z.ts", "src/a.ts"])
    }

    @Test func requireBareImportsAndCycles() {
        #expect(order([("src/a.ts", [#"const b = require("./b");"#, #"import "./c";"#]), ("src/b.ts", []), ("src/c.ts", [])])
            == ["src/b.ts", "src/c.ts", "src/a.ts"])
        #expect(order([("src/b.ts", [#"import { a } from "./a";"#]), ("src/a.ts", [#"import { b } from "./b";"#])]) == ["src/a.ts", "src/b.ts"])
    }

    @Test func testsFollowTheSourceTheyCover() {
        #expect(order([("pnpm-lock.yaml", []), ("src/a.test.ts", []), ("src/__tests__/b.ts", []), ("src/a.ts", [#"import { b } from "./b";"#]),
                       ("src/b.ts", []), ("dist/a.js", [])])
            == ["src/b.ts", "src/a.ts", "src/__tests__/b.ts", "src/a.test.ts", "dist/a.js", "pnpm-lock.yaml"])
        #expect(order(["src/orphan.spec.ts", "src/a.test.ts", "src/a.ts"]) == ["src/a.ts", "src/a.test.ts", "src/orphan.spec.ts"])
        #expect(order(["src/c.browser.test.tsx", "src/b.test.ts", "src/a.logic.test.ts", "src/c.tsx", "src/b.ts", "src/a.logic.ts"])
            == ["src/a.logic.ts", "src/b.ts", "src/c.tsx", "src/a.logic.test.ts", "src/b.test.ts", "src/c.browser.test.tsx"])
    }
}
