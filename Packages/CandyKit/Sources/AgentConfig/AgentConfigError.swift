import Foundation

public enum AgentConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file doesn't parse; nothing was written to it.
    case unreadable(file: String, line: Int, message: String)
    /// The file parses but has a shape CandyWrapper won't edit, like a server defined as an inline table.
    case cannotEdit(String)
    case io(String)

    public var description: String {
        switch self {
        case .unreadable(let file, let line, let message): "\(file) doesn't parse at line \(line): \(message)"
        case .cannotEdit(let why): why
        case .io(let why): why
        }
    }

    /// The same error naming the file it came from; the parsers don't know it.
    func inFile(_ name: String) -> AgentConfigError {
        if case .unreadable(_, let line, let message) = self { return .unreadable(file: name, line: line, message: message) }
        return self
    }
}
