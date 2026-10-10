// Presses a button by title in the frontmost sheet or window of an app (by pid).
// Usage: axpress <pid> <button title>
import ApplicationServices
let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[1]) else { print("usage: axpress <pid> <title>"); exit(2) }
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func find(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as? String) == kAXButtonRole, (attr(e, kAXTitleAttribute) as? String) == args[2] { return e }
    guard depth < 12, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for k in kids { if let hit = find(k, depth: depth + 1) { return hit } }
    return nil
}
guard let button = find(app) else { print("no button titled \(args[2])"); exit(1) }
print("press:", AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
