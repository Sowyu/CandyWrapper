import Foundation
import T3Protocol
import Testing
@testable import CandyHelper

/// A large RPC frame, fed in the pieces curl hands over, comes out whole and decodes. Fed as swift-corelibs-foundation
/// fed it on Linux, one curl callback per message, it didn't (aniko, 2026-10-24).
@Suite struct WebSocketAssemblerTests {
    /// A shell-sized Chunk frame (about 100 KB) with multi-byte characters throughout, so 16 KB cuts land inside some.
    func bigFrame() -> Data {
        let threads = (0..<1_200).map { i in #"{"id":"t\#(i)","title":"Thread \#(i) — café 🍬 ünïcödé","status":"idle"}"# }.joined(separator: ",")
        return Data(#"{"_tag":"Chunk","requestId":"7","values":[{"kind":"snapshot","threads":[\#(threads)]}]}"#.utf8)
    }

    /// curl_ws_recv's view of one frame: pieces of at most `size` bytes, each with the bytes still to come.
    func pieces(_ data: Data, size: Int) -> [(Data, Int)] {
        stride(from: 0, to: data.count, by: size).map { start in
            let end = min(start + size, data.count)
            return (data.subdata(in: start..<end), data.count - end)
        }
    }

    @Test func aFrameInCurlSizedPiecesComesOutWholeAndDecodes() throws {
        let frame = bigFrame()
        // The first cut lands inside a 4-byte emoji, which failed the whole connection on Linux; then 16 KB pieces.
        let inside = frame.firstIndex(of: 0xF0)! + 2
        let cuts = [(frame.prefix(inside), frame.count - inside)] + pieces(Data(frame.suffix(from: inside)), size: 16_384)
        #expect(cuts.count > 4)
        #expect(String(data: cuts[0].0, encoding: .utf8) == nil)
        var assembler = WebSocketAssembler()
        var out: [WebSocketAssembler.Event] = []
        for (piece, left) in cuts { if let e = assembler.feed(piece, flags: WebSocketAssembler.text, bytesLeft: left) { out.append(e) } }
        #expect(out == [.message(frame)])
        let messages = try RPCFrame.decodeServer(frame)
        #expect(messages.count == 1)
    }

    @Test func eachPieceAloneDoesNotDecode() {
        let undecodable = pieces(bigFrame(), size: 16_384).filter { (try? RPCFrame.decodeServer($0.0)) == nil }
        #expect(!undecodable.isEmpty)
    }

    /// A message sent in several WebSocket frames: every fragment but the last carries CURLWS_CONT.
    @Test func fragmentedMessagesJoin() {
        let frame = bigFrame()
        let half = frame.count / 2
        var assembler = WebSocketAssembler()
        #expect(assembler.feed(frame.prefix(half), flags: WebSocketAssembler.text | WebSocketAssembler.cont, bytesLeft: 0) == nil)
        #expect(assembler.feed(frame.suffix(from: half), flags: WebSocketAssembler.text, bytesLeft: 0) == .message(frame))
    }

    @Test func pingsPongsAndCloseCarryNoMessage() {
        var assembler = WebSocketAssembler()
        #expect(assembler.feed(Data("hi".utf8), flags: WebSocketAssembler.ping, bytesLeft: 0) == nil)
        #expect(assembler.feed(Data(), flags: WebSocketAssembler.pong, bytesLeft: 0) == nil)
        #expect(assembler.feed(Data([3, 232]), flags: WebSocketAssembler.close, bytesLeft: 0) == .close)
        #expect(assembler.feed(Data("{}".utf8), flags: WebSocketAssembler.text, bytesLeft: 0) == .message(Data("{}".utf8)))
    }
}
