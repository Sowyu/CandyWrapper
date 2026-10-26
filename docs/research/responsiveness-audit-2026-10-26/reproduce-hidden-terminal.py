#!/usr/bin/env python3
"""Opt-in, bounded reproduction using the checkout's actual buffer and scanner.

Run centrally with CW_ORCHESTRATOR_AUDIT_REGRESSIONS=1. Expected to fail on the
2026-10-26 baseline. No app, server, terminal, config or account is accessed.
"""
import os
from pathlib import Path
import subprocess
import tempfile

if os.environ.get("CW_ORCHESTRATOR_AUDIT_REGRESSIONS") != "1":
    raise SystemExit("Set CW_ORCHESTRATOR_AUDIT_REGRESSIONS=1 to run this known-failing audit reproduction.")
root = Path(__file__).resolve().parents[3]
hidden = (root / "App/Sources/HiddenTerminal.swift").read_text()
start = hidden.index("    private actor OutputBox {")
# Extract the unchanged actor using balanced braces, rather than copying its algorithm.
opening = hidden.index("{", start)
depth = 1
end = opening + 1
while depth:
    depth += (hidden[end] == "{") - (hidden[end] == "}")
    end += 1
buffer_actor = hidden[start:end]
scanner = (root / "Packages/CandyKit/Sources/T3Store/HelperInstall.swift").read_text()
exercise = r'''
enum BufferExercise {
BUFFER_ACTOR
    static func check() async -> Bool {
        var failures = 0
        for count in [1, 400] {
            let servers = (0..<count).map { n in
                ["name": "fixture-\(n)", "agent": "claude", "enabled": true,
                 "transport": "stdio", "summary": String(repeating: "x", count: 120)] as [String: Any]
            }
            let bytes = try! JSONSerialization.data(withJSONObject: ["servers": servers, "skills": [], "problems": []])
            let base64 = bytes.base64EncodedString()
            let wire = "CWH-CONFIG " + base64 + "\r\nCWH-RESULT ok config\r\n"
            for width in [256, 4096, 1_000_000] {
                let box = OutputBox()
                var rest = Substring(wire)
                while !rest.isEmpty {
                    await box.append(String(rest.prefix(width)))
                    rest = rest.dropFirst(width)
                }
                let lines = HelperInstall.scan(await box.text)
                let configs = lines.compactMap { line -> String? in
                    if case .config(let text) = line { return text }; return nil
                }
                let ok = lines.contains { if case .ok = $0 { return true }; return false }
                print("servers=\(count) jsonBytes=\(bytes.count) base64=\(base64.count) chunk=\(width) ok=\(ok) completeSnapshot=\(configs == [base64])")
                if !ok || configs != [base64] { failures += 1 }
            }
        }
        return failures == 0
    }
}
let passed = await BufferExercise.check()
if !passed {
    print("FAIL: HiddenTerminal lost a complete config snapshot while preserving its success result")
    exit(1)
}
'''.replace("BUFFER_ACTOR", buffer_actor)
with tempfile.TemporaryDirectory(prefix="cw-orchestrator-audit-") as directory:
    source = Path(directory) / "main.swift"
    source.write_text(scanner + "\n" + exercise)
    result = subprocess.run(["xcrun", "swift", str(source)], timeout=90)
    raise SystemExit(result.returncode)
