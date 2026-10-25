import Foundation
import Testing
@testable import AgentConfig

struct TOMLDocumentTests {
    private static let fixture = #"""
    # Codex configuration. Keep this file header.
    model = "gpt-5"  # default model
    approval_policy = "on-request"
    # Local preferences
    tools = { web_search = true }

    # GitHub runs over stdio.
    [mcp_servers.github] # server header
      command = "github-mcp-server" # executable
      args = [
        "stdio", # transport
        "--read-only",
      ] # keep array comment

    [mcp_servers.github.env]
    GITHUB_TOOLSETS = "repos,issues" # environment

    # A quoted server name.
    [mcp_servers."my server"]
    url = "https://mcp.example.test/api" # endpoint
    bearer_token_env_var = "MCP_TOKEN"

    # Figma is enabled.
    [mcp_servers.figma]
    enabled = true  # keep
    url = "https://figma.example.test/mcp"

    # Fast profile
    [profiles.fast]
    model = "gpt-5-mini"

    # Skills are ordered.
    [[skills.config]]
    path = "/sandbox/skills/first" # first skill
    enabled = true

    [[skills.config]]
    path = "/sandbox/skills/second" # second skill
    enabled = true # second enabled
    """# + "\n"

    @Test func readsCodexConfigurationAndOrder() throws {
        let doc = try TOMLDocument(Self.fixture)
        #expect(doc.text == Self.fixture)
        #expect(doc.root.tableKeys == ["model", "approval_policy", "tools", "mcp_servers", "profiles", "skills"])
        #expect(doc.value(at: ["model"]) == .string("gpt-5"))
        #expect(doc.value(at: ["mcp_servers", "github"])?.tableKeys == ["command", "args", "env"])
        #expect(doc.value(at: ["mcp_servers", "github", "args"]) == .array([.string("stdio"), .string("--read-only")]))
        #expect(doc.value(at: ["mcp_servers", "my server", "bearer_token_env_var"]) == .string("MCP_TOKEN"))
        #expect(doc.hasHeader(["mcp_servers", "my server"]))
        #expect(doc.value(at: []) == doc.root)
        #expect(doc.value(at: ["missing"]) == nil)
        #expect(doc.arrayOfTables(["skills", "config"]).count == 2)
        #expect(doc.arrayOfTables(["tools"]).isEmpty)
    }

    @Test func insertsExactlyOneLineAndKeepsEveryOtherByte() throws {
        var doc = try TOMLDocument(Self.fixture)
        try doc.set("enabled", to: "false", inTable: ["mcp_servers", "github"])
        let expected = Self.fixture.replacingOccurrences(
            of: "  ] # keep array comment\n", with: "  ] # keep array comment\n  enabled = false\n"
        )
        #expect(doc.text == expected)
        #expect(doc.value(at: ["mcp_servers", "github", "enabled"]) == .bool(false))
        try doc.set("enabled", to: "false", inTable: ["mcp_servers", "github"])
        #expect(doc.text == expected)
    }

    @Test func replacesOnlyValueAndKeepsComment() throws {
        var doc = try TOMLDocument(Self.fixture)
        try doc.set("enabled", to: "false", inTable: ["mcp_servers", "figma"])
        #expect(doc.text == Self.fixture.replacingOccurrences(of: "enabled = true  # keep", with: "enabled = false  # keep"))
        var quoted = try TOMLDocument("[server]\n\t'enabled' \t=  true\t # keep # all\n")
        try quoted.set("enabled", to: "false", inTable: ["server"])
        #expect(quoted.text == "[server]\n\t'enabled' \t=  false\t # keep # all\n")
    }

    @Test func replacesMultilineStatementAndRemovesWholeStatement() throws {
        var doc = try TOMLDocument(Self.fixture)
        try doc.set("args", to: #"["new"]"#, inTable: ["mcp_servers", "github"])
        let old = "  args = [\n    \"stdio\", # transport\n    \"--read-only\",\n  ] # keep array comment"
        #expect(doc.text == Self.fixture.replacingOccurrences(of: old, with: "  args = [\"new\"] # keep array comment"))
        var removed = try TOMLDocument(Self.fixture)
        try removed.remove("args", inTable: ["mcp_servers", "github"])
        #expect(removed.text == Self.fixture.replacingOccurrences(of: old + "\n", with: ""))
        try removed.remove("absent", inTable: ["mcp_servers", "github"])
        #expect(removed.value(at: ["mcp_servers", "github", "args"]) == nil)
        var string = try TOMLDocument("[s]\nx = \"\"\"\n[not.a.header]\n# inside string\n\"\"\"  # tail\ny = 1\n")
        try string.set("x", to: "7", inTable: ["s"])
        #expect(string.text == "[s]\nx = 7  # tail\ny = 1\n")
    }

    @Test func removesTableAndEnvAndKeepsOtherSections() throws {
        var doc = try TOMLDocument(Self.fixture)
        try doc.removeTable(["mcp_servers", "github"])
        let start = try #require(Self.fixture.range(of: "[mcp_servers.github]"))
        let end = try #require(Self.fixture.range(of: "[mcp_servers.\"my server\"]"))
        let expected = String(Self.fixture[..<start.lowerBound]) + String(Self.fixture[end.lowerBound...])
        #expect(doc.text == expected)
        #expect(doc.value(at: ["mcp_servers", "github"]) == nil)
        #expect(doc.hasHeader(["profiles", "fast"]))
        let unchanged = doc.text
        try doc.removeTable(["absent"])
        #expect(doc.text == unchanged)
    }

    @Test func removesNoncontiguousDescendantsAndCollapsesOnlyRemovalSeams() throws {
        let input = "# root\n\n\n[a]\nx=1\n[b]\ny=2\n\n\n[a.child]\nz=3\n[[a.entries]]\nx=1\n[c]\nz=4\n\n\n"
        var doc = try TOMLDocument(input)
        try doc.removeTable(["a"])
        #expect(doc.text == "# root\n\n[b]\ny=2\n\n[c]\nz=4\n\n\n")
        var implicit = try TOMLDocument("[parent.child]\nx=1\n[other]\ny=2\n")
        try implicit.removeTable(["parent"])
        #expect(implicit.text == "[other]\ny=2\n")
    }

    @Test func appendsTablesAndArrayEntries() throws {
        var doc = try TOMLDocument(Self.fixture)
        try doc.appendTable(["mcp_servers", "new server"], entries: [("url", TOMLDocument.literal("https://new.example.test")), ("enabled", "false")])
        let addition = "\n[mcp_servers.\"new server\"]\nurl = \"https://new.example.test\"\nenabled = false\n"
        #expect(doc.text == Self.fixture + addition)
        try doc.appendArrayEntry(["skills", "config"], entries: [("path", #""/sandbox/skills/third""#), ("enabled", "false")])
        #expect(doc.text == Self.fixture + addition + "\n[[skills.config]]\npath = \"/sandbox/skills/third\"\nenabled = false\n")
        #expect(doc.arrayOfTables(["skills", "config"]).count == 3)
        var empty = try TOMLDocument("")
        try empty.appendTable(["empty"], entries: [])
        #expect(empty.text == "[empty]\n")
        var blank = try TOMLDocument("# header\n\n")
        try blank.appendArrayEntry(["entries"], entries: [])
        #expect(blank.text == "# header\n\n[[entries]]\n")
    }

    @Test func editsSecondArrayEntryAndReparsesIndexes() throws {
        var doc = try TOMLDocument(Self.fixture)
        try doc.set("enabled", to: "false", inArrayOfTables: ["skills", "config"], index: 1)
        #expect(doc.text == Self.fixture.replacingOccurrences(of: "enabled = true # second enabled", with: "enabled = false # second enabled"))
        #expect(doc.arrayOfTables(["skills", "config"])[0]["enabled"] == .bool(true))
        #expect(doc.arrayOfTables(["skills", "config"])[1]["enabled"] == .bool(false))
        try doc.removeArrayEntry(["skills", "config"], index: 0)
        let first = try #require(Self.fixture.range(of: "[[skills.config]]"))
        let second = try #require(Self.fixture.range(of: "[[skills.config]]", range: first.upperBound..<Self.fixture.endIndex))
        let expected = String(Self.fixture[..<first.lowerBound]) + String(Self.fixture[second.lowerBound...])
            .replacingOccurrences(of: "enabled = true # second enabled", with: "enabled = false # second enabled")
        #expect(doc.text == expected)
        try doc.set("enabled", to: "true", inArrayOfTables: ["skills", "config"], index: 0)
        #expect(doc.arrayOfTables(["skills", "config"]).count == 1)
        #expect(doc.arrayOfTables(["skills", "config"])[0]["enabled"] == .bool(true))
    }

    @Test func nestedArrayHeadersAreReadInFileOrder() throws {
        let doc = try TOMLDocument("[[fruit]]\nname='apple'\n[fruit.physical]\ncolor='red'\n[[fruit.varieties]]\nname='sweet'\n[[fruit]]\nname='banana'\n[[fruit.varieties]]\nname='yellow'\n")
        #expect(doc.arrayOfTables(["fruit"]).count == 2)
        #expect(doc.arrayOfTables(["fruit"])[0]["physical"]?["color"] == .string("red"))
        #expect(doc.arrayOfTables(["fruit", "varieties"]).map { $0["name"] } == [.string("sweet"), .string("yellow")])
    }

    @Test func refusesUnsupportedShapesAndRollsBackInvalidEdits() throws {
        var inline = try TOMLDocument("mcp_servers.github = { enabled = true }\n")
        #expect(!inline.hasHeader(["mcp_servers", "github"]))
        #expect(inline.value(at: ["mcp_servers", "github", "enabled"]) == .bool(true))
        try cannotEdit { try inline.set("enabled", to: "false", inTable: ["mcp_servers", "github"]) }
        try cannotEdit { try inline.appendTable(["mcp_servers", "github"], entries: []) }
        var doc = try TOMLDocument(Self.fixture)
        try cannotEdit { try doc.set("enabled", to: "[bad", inTable: ["mcp_servers", "figma"]) }
        try cannotEdit { try doc.set("enabled", to: "false\ninjected = true", inTable: ["mcp_servers", "figma"]) }
        try cannotEdit { try doc.set("enabled", to: "false # injected", inTable: ["mcp_servers", "figma"]) }
        try cannotEdit { try doc.appendTable(["model", "nested"], entries: []) }
        try cannotEdit { try doc.appendTable(["new"], entries: [("x", "1"), ("x", "2")]) }
        try cannotEdit { try doc.appendArrayEntry(["model"], entries: []) }
        try cannotEdit { try doc.removeArrayEntry(["skills", "config"], index: -1) }
        try cannotEdit { try doc.set("x", to: "1", inArrayOfTables: ["skills", "config"], index: 2) }
        #expect(doc.text == Self.fixture)
        var dotted = try TOMLDocument("[a]\nb.c = 1\n")
        try cannotEdit { try dotted.set("b", to: "2", inTable: ["a"]) }
        try cannotEdit { try dotted.remove("b", inTable: ["a"]) }
        #expect(dotted.text == "[a]\nb.c = 1\n")
    }

    @Test func preservesCRLFAndMissingFinalNewline() throws {
        let crlf = Self.fixture.replacingOccurrences(of: "\n", with: "\r\n")
        var doc = try TOMLDocument(crlf)
        try doc.set("enabled", to: "false", inTable: ["mcp_servers", "github"])
        #expect(doc.text == crlf.replacingOccurrences(of: "  ] # keep array comment\r\n", with: "  ] # keep array comment\r\n  enabled = false\r\n"))
        try doc.appendTable(["new"], entries: [("x", "1")])
        #expect(doc.text.hasSuffix("\r\n\r\n[new]\r\nx = 1\r\n"))
        #expect(!doc.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        var unterminated = try TOMLDocument("[a]\r\nx = true # keep")
        try unterminated.set("x", to: "false", inTable: ["a"])
        #expect(unterminated.text == "[a]\r\nx = false # keep")
        try unterminated.set("y", to: "2", inTable: ["a"])
        #expect(unterminated.text == "[a]\r\nx = false # keep\r\ny = 2")
        try unterminated.appendTable(["b"], entries: [("x", "3")])
        #expect(unterminated.text == "[a]\r\nx = false # keep\r\ny = 2\r\n\r\n[b]\r\nx = 3")
        try unterminated.removeTable(["b"])
        #expect(unterminated.text.utf8.last != 0x0A)
        var emptySection = try TOMLDocument("[a]")
        try emptySection.set("x", to: "1", inTable: ["a"])
        #expect(emptySection.text == "[a]\nx = 1")
        var emptied = try TOMLDocument("[a]\r\nx=1\r\n")
        try emptied.removeTable(["a"])
        #expect(emptied.text.isEmpty)
        try emptied.appendArrayEntry(["b"], entries: [("x", "2")])
        #expect(emptied.text == "[[b]]\r\nx = 2\r\n")
    }

    @Test func quotedKeysAndEscapedLiteralsRoundTrip() throws {
        let strings = ["", "bare", "abc-DEF_09", "0", "with space", "a.b", "snow ☃", "\"quote\\", "\u{00}\u{01}\u{08}\t\n\u{0C}\r\u{1F}\u{7F}", "e\u{301}"]
        for key in strings {
            var doc = try TOMLDocument("")
            try doc.appendTable([key], entries: [(key, TOMLDocument.literal(key))])
            #expect(doc.value(at: [key, key]) == .string(key))
            try doc.set(key, to: TOMLDocument.literal("changed"), inTable: [key])
            #expect(doc.value(at: [key, key]) == .string("changed"))
        }
        #expect(TOMLDocument.key("") == #""""#)
        #expect(TOMLDocument.key("abc-DEF_09") == "abc-DEF_09")
        #expect(TOMLDocument.key("a.b") == #""a.b""#)
        let inline = TOMLDocument.inlineTable([("a.b", "value"), ("plain", "other")])
        #expect(try TOMLDocument("x = " + inline).value(at: ["x", "a.b"]) == .string("value"))
    }

    @Test func distinguishesUnicodeKeySpellings() throws {
        let composed = "é"
        let decomposed = "e\u{301}"
        var doc = try TOMLDocument("[\"" + composed + "\"]\nx=1\n[\"" + decomposed + "\"]\nx=2\n")
        #expect(doc.value(at: [composed, "x"]) == .integer(1))
        #expect(doc.value(at: [decomposed, "x"]) == .integer(2))
        try doc.set("x", to: "3", inTable: [decomposed])
        #expect(Array(doc.text.utf8) == Array(("[\"" + composed + "\"]\nx=1\n[\"" + decomposed + "\"]\nx=3\n").utf8))
        try doc.removeTable([composed])
        #expect(Array(doc.text.utf8) == Array(("[\"" + decomposed + "\"]\nx=3\n").utf8))
    }

    @Test func insertsAtEmptyHeaderAndKeepsMixedEndings() throws {
        var doc = try TOMLDocument("# header\r\n[a] # table\r\n# section comment\n[b]\nx=1\n")
        try doc.set("enabled", to: "false", inTable: ["a"])
        #expect(doc.text == "# header\r\n[a] # table\r\nenabled = false\r\n# section comment\n[b]\nx=1\n")
    }

    @Test func parsesEveryValueKind() throws {
        let cases: [(String, TOMLValue)] = [
            (#""hello\b\t\n\f\r\"\\\u0041\U0001F600""#, .string("hello\u{08}\t\n\u{0C}\r\"\\A😀")),
            (#"'C:\literal\path'"#, .string(#"C:\literal\path"#)),
            ("\"\"\"\nhello\nworld\"\"\"", .string("hello\nworld")),
            ("'''\nraw\\path\nnext'''", .string("raw\\path\nnext")),
            ("\"\"\"one \\ \t\n \n  two\"\"\"", .string("one two")),
            (#"""""quoted"""""#, .string(#""quoted""#)),
            ("''''quoted''''", .string("'quoted'")),
            ("+99", .integer(99)), ("-0", .integer(0)), ("1_000", .integer(1000)),
            ("-9223372036854775808", .integer(.min)), ("9223372036854775807", .integer(.max)),
            ("0xDEAD_beef", .integer(3735928559)), ("0o7_55", .integer(493)), ("0b1_010", .integer(10)),
            ("+1.5", .float(1.5)), ("6.626e-34", .float(6.626e-34)), ("1_2.3_4e+0_2", .float(1234)),
            ("1e06", .float(1e6)), ("inf", .float(.infinity)), ("-inf", .float(-.infinity)),
            ("nan", .float(.nan)), ("+nan", .float(.nan)), ("-nan", .float(.nan)),
            ("true", .bool(true)), ("false", .bool(false)),
            ("1979-05-27T07:32:00Z", .datetime("1979-05-27T07:32:00Z")),
            ("1979-05-27 07:32:00.123-07:00", .datetime("1979-05-27 07:32:00.123-07:00")),
            ("2000-02-29t07:32:00z", .datetime("2000-02-29t07:32:00z")),
            ("1979-05-27T07:32:00.123", .datetime("1979-05-27T07:32:00.123")),
            ("1979-05-27", .datetime("1979-05-27")), ("07:32:00.123", .datetime("07:32:00.123")),
            ("[1, # comment\n true, ['x'],]", .array([.integer(1), .bool(true), .array([.string("x")])])),
            ("{ a.b = 1, a.c = false }", .table([("a", .table([("b", .integer(1)), ("c", .bool(false))]))])),
            ("{ a = [\n1,\n] }", .table([("a", .array([.integer(1)]))])),
        ]
        for (source, expected) in cases {
            let doc = try TOMLDocument("value = " + source + "\n")
            #expect(doc.value(at: ["value"]) == expected, "Value: \(source)")
        }
        let dotted = try TOMLDocument("'a.b'.\"c d\" = 1\na.other = 2\n[a.child]\nx=3\n")
        #expect(dotted.value(at: ["a.b", "c d"]) == .integer(1))
        #expect(dotted.value(at: ["a", "other"]) == .integer(2))
        let implicit = try TOMLDocument("[a.b]\nx=1\n[a]\ny=2\n")
        #expect(implicit.value(at: ["a"])?.tableKeys == ["b", "y"])
    }

    @Test func invalidDocumentsReportOneBasedLine() throws {
        let cases: [(String, Int)] = [
            ("# header\nx = 1\nx = 2\n", 3),
            ("x = 1\n\"x\" = 2", 2),
            ("# header\nx = \"unterminated\n", 2),
            ("# header\nx = \"\"\"unterminated\nnext\n", 2),
            ("# header\n[bad\nx=1", 2),
            ("[a]\nx=1\n[a]\n", 3),
            ("a.b = 1\n[a]\n", 2),
            ("a = { b = 1 }\n[a.c]\n", 2),
            ("[a.b]\nx=1\n[a]\nb.y=2\n", 4),
            ("a.b=1\na.b.c=2", 2),
            ("a=[]\n[[a]]", 2),
            ("[[a]]\n[a]", 2),
            ("[a.b]\n[[a]]", 2),
            ("a={x=1}\na.y=2", 2),
            ("a={x={b=1},x.c=2}", 1),
            ("a = [\n 1\n 2\n]", 3),
            ("a = [\n 1,\n bad\n]", 3),
            ("a = \"bad\\q\"", 1), ("a = \"\\uD800\"", 1),
            ("a = \"\\U00110000\"", 1), ("a=\"control\u{7F}\"", 1),
            ("# bad\u{00}\n", 1), ("a=1\rb=2", 1),
            ("a = 9223372036854775808", 1), ("a = 0x8000000000000000", 1),
            ("a = 01", 1), ("a=+0x1", 1), ("a=1__0", 1), ("a=0x_FF", 1),
            ("a=1.", 1), ("a=.1", 1), ("a=01.2", 1), ("a=1e_2", 1),
            ("a=2023-02-29", 1), ("a=2000-13-01", 1), ("a=25:00:00", 1),
            ("a=2000-01-01T12:00:00+24:00", 1),
            ("a={x=1,}", 1), ("a={\nx=1}", 1), ("a={x=1 # bad\n}", 1),
            ("a=true extra=1", 1), ("[a] extra=1", 1),
        ]
        for (source, line) in cases {
            do {
                _ = try TOMLDocument(source)
                Issue.record("Accepted invalid TOML: \(source)")
            } catch let error as AgentConfigError {
                guard case .unreadable(let file, let actualLine, _) = error else {
                    Issue.record("Wrong error: \(error)"); continue
                }
                #expect(file == "")
                #expect(actualLine == line, "Source: \(source)")
            }
        }
    }

    private func cannotEdit(_ action: () throws -> Void) throws {
        do {
            try action()
            Issue.record("Expected cannotEdit")
        } catch let error as AgentConfigError {
            guard case .cannotEdit = error else { Issue.record("Wrong error: \(error)"); return }
        }
    }
}
