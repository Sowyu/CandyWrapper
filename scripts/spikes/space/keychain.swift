import Foundation
import Security

// Isolated synthetic key only. Every query names this probe's service and account.
let service = "dev.candywrapper.space-spike"
let account = "release-probe"
let group = "8Q677AYRU7.dev.candywrapper.space-spike"
let mode = CommandLine.arguments.dropFirst().first ?? "dp"
let key = Data((0..<32).map { UInt8($0) })
var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
    kSecAttrService: service, kSecAttrAccount: account, kSecAttrSynchronizable: false]
SecKeychainSetUserInteractionAllowed(false)
if mode == "dp" {
    query[kSecUseDataProtectionKeychain] = true
    query[kSecAttrAccessGroup] = group
} else {
    var trusted: SecTrustedApplication?
    let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trusted)
    guard trustedStatus == 0, let trusted else { fatalError("trusted application creation failed") }
    var access: SecAccess?
    let accessStatus = SecAccessCreate("Space spike key" as CFString, [trusted] as CFArray, &access)
    guard accessStatus == 0 else { fatalError("ACL creation failed") }
    query[kSecAttrAccess] = access!
}
if mode == "acl-read" || mode == "acl-delete" {
    query.removeValue(forKey: kSecAttrAccess)
    if mode == "acl-delete" {
        print("delete=\(SecItemDelete(query as CFDictionary))")
    } else {
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        print("read=\(status); matches32Bytes=\((result as? Data) == key)")
    }
    exit(0)
}
let deleteBefore = SecItemDelete(query as CFDictionary)
var item = query
item[kSecValueData] = key
item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
let begin = DispatchTime.now().uptimeNanoseconds
let add = SecItemAdd(item as CFDictionary, nil)
let addMS = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6
query.removeValue(forKey: kSecAttrAccess)
query[kSecReturnData] = true
query[kSecMatchLimit] = kSecMatchLimitOne
var result: CFTypeRef?
let readBegin = DispatchTime.now().uptimeNanoseconds
let read = SecItemCopyMatching(query as CFDictionary, &result)
let readMS = Double(DispatchTime.now().uptimeNanoseconds - readBegin) / 1e6
query.removeValue(forKey: kSecReturnData)
query.removeValue(forKey: kSecMatchLimit)
let deleted: Any = mode == "acl-write" ? NSNull() : SecItemDelete(query as CFDictionary)
func message(_ code: OSStatus) -> String { SecCopyErrorMessageString(code, nil) as String? ?? "unknown" }
let output: [String: Any] = ["mode": mode, "deleteBefore": deleteBefore, "add": add,
    "addMessage": message(add), "read": read, "readMessage": message(read),
    "matches32Bytes": (result as? Data) == key, "deleteAfter": deleted,
    "addMS": addMS, "readMS": readMS]
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
