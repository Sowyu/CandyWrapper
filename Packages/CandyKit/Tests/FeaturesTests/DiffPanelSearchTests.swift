import Testing
@testable import Features

struct DiffPanelSearchTests {
    let patch = """
    diff --git a/src/a.swift b/src/a.swift
    --- a/src/a.swift
    +++ b/src/a.swift
    @@ -1,2 +1,2 @@
    -let oldName = 1
    +let newName = oldName
     // Name names
    """
    @Test func searchesBothSidesAndContextOnce() {
        let diff = UnifiedDiff(patch)
        #expect(DiffPanelSearch.matches("oldName", in: diff).count == 2)
        #expect(DiffPanelSearch.matches("Name", in: diff, caseSensitive: true).count == 4)
        #expect(DiffPanelSearch.matches("name", in: diff, wholeWord: true).count == 1)
        #expect(DiffPanelSearch.matches("(", in: diff, regex: true).isEmpty)
        #expect(DiffPanelSearch.matches("", in: diff).isEmpty)
    }
    @Test func treeOpensAncestors() {
        let model = DiffPanelSearch.tree(UnifiedDiff(patch))
        #expect(model.expanded.contains("src"))
        #expect(model.rows.last?.path == "src/a.swift")
    }
}
