import Foundation
import Testing
@testable import AgentConfig

struct OrderedJSONTests {
    @Test func roundTripAndEditing() throws {
        let text = #"""
        {
          "numStartups": 12345678901234567890,
          "theme": "dark",
          "projects": {
            "/sandbox/café": {
              "allowedTools": [
                "Read",
                "Bash"
              ],
              "mcpServers": {},
              "history": [],
              "trusted": true,
              "disabled": false,
              "lastCost": 1.5e-3,
              "offset": -0,
              "session": null,
              "note": "café 😀\n\"hello\"\\\b\f\r\t\u0000\u001f"
            }
          },
          "duplicate": 1,
          "duplicate": 2
        }
        """#
        var value = try OrderedJSON.parse(text)
        #expect(value.serialized() == text)
        #expect(value.members?.map(\.key) == ["numStartups", "theme", "projects", "duplicate", "duplicate"])
        value["theme"] = .string("light")
        #expect(value.serialized() == text.replacingOccurrences(of: #""dark""#, with: #""light""#))
        value["new"] = .null
        #expect(value.members?.last?.key == "new")
        value["duplicate"] = nil
        #expect(value.members?.map(\.key) == ["numStartups", "theme", "projects", "new"])
    }

    @Test func escapesWhitespaceAndCompactOutput() throws {
        let value = try OrderedJSON.parse("\u{FEFF} \t\r\n" + #"["\uD83D\uDE00", "\ud800", "\udc00", "\ud800\u0041", "\/\u00e9", {}, []]"#)
        #expect(value.serialized(indent: "") == #"["😀","�","�","�A","/é",{},[]]"#)
        #expect(try OrderedJSON.parse("[0,-0,1E+3,0.25,1e-2]").serialized(indent: "") == "[0,-0,1E+3,0.25,1e-2]")
        #expect(OrderedJSON.array([.null]).serialized(indent: "0123456789extra") == "[\n0123456789null\n]")
    }

    @Test func invalidInputsHaveLocations() throws {
        let cases: [(String, Int, Int)] = [
            ("{\n  \"a\": 1,\n}", 3, 1),
            ("[\n  1,\n]", 3, 1),
            ("{\n  \"a\": \"unfinished", 2, 19),
            ("{\n  // comment\n}", 2, 3),
            ("true\n  garbage", 2, 3),
            ("[\"a\n\"]", 1, 4),
            ("\r\n?", 2, 1)
        ]
        for (text, line, column) in cases {
            do {
                _ = try OrderedJSON.parse(text)
                Issue.record("Accepted invalid JSON: \(text)")
            } catch let error as AgentConfigError {
                guard case .unreadable(let file, let actualLine, let message) = error else {
                    Issue.record("Wrong error: \(error)"); continue
                }
                #expect(file.isEmpty)
                #expect(actualLine == line)
                #expect(message.hasSuffix("at column \(column)"))
            }
        }
        for text in ["", "01", "-01", "+1", ".1", "1.", "1e", "1e+", "NaN", "Infinity", "[true false]", "{\"a\" 1}", #""\x00""#, #""\u12xz""#, "null\u{00a0}"] {
            #expect(throws: AgentConfigError.self) { try OrderedJSON.parse(text) }
        }
    }

    @Test func indentDetection() {
        #expect(OrderedJSON.detectIndent("{\n    \"a\": {\n        \"b\": 1\n    }\n}") == "    ")
        #expect(OrderedJSON.detectIndent("{\r\n\t\"a\": 1\r\n}") == "\t")
        #expect(OrderedJSON.detectIndent("{}") == "  ")
        #expect(OrderedJSON.detectIndent("{\n  \"a\": 1\n}") == "  ")
    }

    @Test func twoMegabytesWithinTwoSeconds() throws {
        let entry = #"{"path":"/sandbox/café","tools":["Read","Bash"],"enabled":true,"cost":1.5e-3,"id":12345678901234567890}"#
        let text = "[" + Array(repeating: entry, count: 2_100_000 / entry.utf8.count + 1).joined(separator: ",") + "]"
        #expect(text.utf8.count >= 2_000_000)
        let start = Date()
        let result = try OrderedJSON.parse(text).serialized(indent: "")
        let elapsed = Date().timeIntervalSince(start)
        #expect(result == text)
        #expect(elapsed < 2, "Parsing and serializing took \(elapsed) seconds")
    }
}
