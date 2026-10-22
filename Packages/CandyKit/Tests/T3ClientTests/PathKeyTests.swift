import Testing
@testable import T3Client

/// The network-change dedupe behind `PlatformSignals`: only a move to another network makes the
/// supervisor reconnect, so cost or constraint flag updates on the same network don't churn the socket.
struct PathKeyTests {
    let home = PathKey(interfaces: ["en0"], gateways: ["192.0.2.1", "fe80::1%en0"])

    @Test func sameNetworkInAnyGatewayOrderIsNoMove() {
        let again = PathKey(interfaces: ["en0"], gateways: ["fe80::1%en0", "192.0.2.1"])
        #expect(again == home)
        #expect(!PathKey.moved(from: home, to: again, online: true))
    }

    @Test func anotherInterfaceOrGatewayIsAMove() {
        #expect(PathKey.moved(from: home, to: PathKey(interfaces: ["en1"], gateways: ["192.0.2.1", "fe80::1%en0"]), online: true))
        #expect(PathKey.moved(from: home, to: PathKey(interfaces: ["en0"], gateways: ["198.51.100.1"]), online: true))
    }

    @Test func firstUpdateAndOfflineUpdatesAreNoMove() {
        let other = PathKey(interfaces: ["en1"], gateways: ["198.51.100.1"])
        #expect(!PathKey.moved(from: nil, to: home, online: true))
        #expect(!PathKey.moved(from: home, to: other, online: false))
    }
}
