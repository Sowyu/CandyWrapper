// Signs only the generated sandbox attachments. Never connects to a live server.
import Foundation
let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("CandyWrapper-research/sandbox")
let manifestURL = root.appendingPathComponent("html-benchmark/manifest.json")
var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
let base = URL(string: "http://127.0.0.1:47391")!
let token = try String(contentsOf: root.appendingPathComponent("session.token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
var req = URLRequest(url: base.appendingPathComponent("api/auth/websocket-ticket")); req.httpMethod = "POST"
req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
req.setValue("2", forHTTPHeaderField: "x-t3-orchestration-protocol")
let (data, response) = try await URLSession.shared.data(for: req)
guard (response as! HTTPURLResponse).statusCode == 200 else { fatalError("Sandbox ticket failed") }
let ticket = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["ticket"] as! String
var c = URLComponents(string: "ws://127.0.0.1:47391/ws")!
c.queryItems = [URLQueryItem(name:"orchestrationProtocol",value:"2"),URLQueryItem(name:"wsTicket",value:ticket)]
let ws = URLSession.shared.webSocketTask(with:c.url!); ws.resume()
func request(_ id: String, _ resource: [String: Any]) async throws -> [String: Any] {
    let obj:[String:Any] = ["_tag":"Request","id":id,"tag":"assets.createUrl","payload":["resource":resource],"headers":[]]
    try await ws.send(.string(String(decoding:JSONSerialization.data(withJSONObject:obj),as:UTF8.self)))
    while true {
        guard case .string(let text) = try await ws.receive() else { continue }
        let raw = try JSONSerialization.jsonObject(with:Data(text.utf8))
        for m in (raw as? [[String:Any]]) ?? [(raw as? [String:Any]) ?? [:]] {
            if m["_tag"] as? String == "Exit", m["requestId"] as? String == id {
                let e = m["exit"] as! [String:Any]
                guard e["_tag"] as? String == "Success", let v = e["value"] as? [String:Any] else { fatalError("Sandbox asset signing failed: \(e)") }
                return v
            }
        }
    }
}
var cases = manifest["cases"] as! [String:[String:Any]]
for kind in cases.keys.sorted() {
    var entry = cases[kind]!, pages = entry["pages"] as! [[String:Any]]
    for i in pages.indices {
        let page = pages[i]
        let reply = try await request("\(kind)-\(i)",["_tag":"attachment","attachmentId":page["attachmentId"]!,"fileName":page["fileName"]!,"mimeType":"text/html","disposition":"inline"])
        pages[i]["url"] = URL(string:reply["relativeUrl"] as! String,relativeTo:base)!.absoluteString
    }
    entry["pages"] = pages; cases[kind] = entry
}
manifest["cases"] = cases
try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:manifestURL)
ws.cancel(with:.normalClosure,reason:nil)
print("Signed 30 sandbox attachment URLs")
