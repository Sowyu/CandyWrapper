import AppKit
let pid = pid_t(CommandLine.arguments[1])!
print("activated:", NSRunningApplication(processIdentifier: pid)?.activate() ?? false)
