import Foundation

/// Sample patches for the gallery and the fidelity tests.
public enum DiffPreview {
    /// A modified TypeScript file with two hunks and a missing final newline, a new Python file
    /// and a deleted JSON file (the cases of scripts/gen-diff-spec.py).
    public static let sample = """
    diff --git a/src/greet.ts b/src/greet.ts
    index 1a2b3c4..5d6e7f8 100644
    --- a/src/greet.ts
    +++ b/src/greet.ts
    @@ -3,6 +3,7 @@ import { format } from "./format";
     // Greets people by name.
    -export function greet(name: string) {
    -  return "Hello " + name;
    +export function greet(name: string): string {
    +  const trimmed = name.trim();
    +  return `Hello, ${trimmed}!`;
     }
    \u{20}
     const LIMIT = 42;
    @@ -20,3 +21,3 @@ export const VERSION = 1;
     export function wave() {
    -  return "bye";
    +  return "wave";
     }
    \\ No newline at end of file
    diff --git a/notes.py b/notes.py
    new file mode 100644
    index 0000000..41b0019
    --- /dev/null
    +++ b/notes.py
    @@ -0,0 +1,5 @@
    +def total(items):
    +    \"\"\"Sum the prices of items.\"\"\"
    +    return sum(item.price for item in items)
    +
    +print(total([]))  # 0
    diff --git a/old.json b/old.json
    deleted file mode 100644
    index 41b0019..0000000
    --- a/old.json
    +++ /dev/null
    @@ -1,4 +0,0 @@
    -{
    -  "name": "demo",
    -  "version": 2
    -}

    """

    /// The uncommitted files of references 09 and 10 (design/reference/README.md: the CandyWrapper
    /// repo's own changes at capture time), as new files with the counts the captures show.
    public static let referenceFiles: [(path: String, additions: Int)] = [
        (".gitignore", 5), ("CLAUDE.md", 63), ("docs/benchmarks.md", 51), ("docs/parity-checklist.md", 682),
        ("docs/protocol.md", 2000), ("docs/research/A-rpc-catalog.md", 197), ("docs/research/B-orchestration.md", 1200),
        ("docs/research/C-auth-connect.md", 1200), ("docs/research/D-server-features.md", 384),
        ("docs/research/E-design-tokens.md", 984), ("docs/research/F-ui-inventory.md", 213),
        ("docs/research/recovered/clerk-connect-client.md", 458), ("docs/research/recovered/client-reducers.md", 949),
        ("docs/research/recovered/compatibility-rules.md", 419), ("docs/research/recovered/connection-runtime.md", 579),
        ("docs/research/recovered/contracts-domain-model.md", 1200), ("docs/research/recovered/local-server-cli.md", 642),
        ("docs/research/recovered/relay-worker.md", 576), ("docs/research/recovered/server-streams.md", 910),
        ("docs/research/recovered/sidebar-derived-state.md", 726), ("docs/research/recovered/thread-project-commands.md", 553),
        ("docs/research/recovered/turn-lifecycle.md", 806),
        // Files below the captured area, so the panel total reads +21k like the captures.
        ("docs/research/recovered/zz-below-the-fold.md", 6200),
    ]

    public static func referencePatch() -> String {
        var patch = ""
        for file in referenceFiles {
            patch += "diff --git a/\(file.path) b/\(file.path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(file.path)\n@@ -0,0 +1,\(file.additions) @@\n"
            for i in 0..<file.additions { patch += "+line \(i)\n" }
        }
        return patch
    }
}
