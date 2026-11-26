// Wire types for the T3 Code server protocol. See docs/protocol.md. Filled in from milestone 3.
public enum T3Protocol {
    public static let orchestrationProtocolVersion = 2

    /// The socket URL's `clientCapabilities`: wire shapes this client decodes, comma-separated (environment.ts:18-23,
    /// server ws.ts:821-827). A client that omits one gets the older shape, so add a name only once its decoder exists.
    /// T3's own client sends `settingsSecretReferences` and `httpUsageLimitSources` (client-runtime
    /// connection/compatibility.ts:56-63). CandyWrapper sends neither yet: its settings read secret fields as strings
    /// and the settings payload's `http` usage sources stay unread, and the server sends those shapes only when asked. Snapshots
    /// carry `http` sources either way, and `UsageLimitSourceSnapshot.list` reads them for their quota accounts.
    public static let clientCapabilities: [String] = []

    /// The `clientCapabilities` query item, or nil while the list is empty.
    public static var clientCapabilitiesQueryItem: (name: String, value: String)? {
        clientCapabilities.isEmpty ? nil : ("clientCapabilities", clientCapabilities.joined(separator: ","))
    }
}
