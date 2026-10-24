import Foundation
import CryptoKit

// Encrypt synthetic PNGs in 1 MiB chunks. The disposable key exists only in this process.
// Verify authenticated decryption before discarding the key; the transport then checks ciphertext equality.
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let key = SymmetricKey(size: .bits256)
for size in [1, 5, 20] {
    let image = try Data(contentsOf: folder.appending(path: "image-\(size).png"))
    var chunks: [Data] = []
    for offset in stride(from: 0, to: image.count, by: 1_048_576) {
        let part = image.subdata(in: offset..<min(offset + 1_048_576, image.count))
        let encrypted = try AES.GCM.seal(part, using: key, authenticating: Data("cws1|spike|\(size)|\(offset / 1_048_576)".utf8))
        let decrypted = try AES.GCM.open(encrypted, using: key, authenticating: Data("cws1|spike|\(size)|\(offset / 1_048_576)".utf8))
        precondition(decrypted == part)
        chunks.append(encrypted.combined!)
        try encrypted.combined!.write(to: folder.appending(path: "image-\(size)-\(offset / 1_048_576).ct"))
    }
    print("\(size) MiB PNG; \(chunks.count) chunks; \(chunks.reduce(0) { $0 + $1.count }) encrypted bytes; AES-GCM round trip verified")
}
