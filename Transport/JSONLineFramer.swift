import Foundation

enum RPCError: Error, Equatable, Sendable {
    case disconnected, timeout, invalidMessage, messageTooLarge, unsupportedMethod, cancelled
    case server(code: Int, category: ServerErrorCategory)
}

enum ServerErrorCategory: String, Sendable { case authentication, unsupported, other }

struct JSONLineFramer {
    static let maximumBytes = 1_048_576
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            let length = buffer.distance(from: buffer.startIndex, to: newline)
            guard length <= Self.maximumBytes else { throw RPCError.messageTooLarge }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        guard buffer.count <= Self.maximumBytes else { throw RPCError.messageTooLarge }
        return lines
    }
}
