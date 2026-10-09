import Foundation

/// Data-only JSON used on both sides of the Host bridge. Unlike JSONDecoder's
/// keyed containers, this parser rejects duplicate fields at every depth.
nonisolated indirect enum PluginBridgeJSON: Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([PluginBridgeJSON])
    case object([String: PluginBridgeJSON])

    enum ParseError: Error { case invalidJSON, limitExceeded }

    static func parse(_ source: String, maximumBytes: Int = 16_384,
                      maximumDepth: Int = 12, maximumNodes: Int = 512) throws -> Self {
        guard source.utf8.count <= maximumBytes else { throw ParseError.limitExceeded }
        var parser = Parser(bytes: Array(source.utf8), maximumDepth: maximumDepth, maximumNodes: maximumNodes)
        let value = try parser.value(depth: 1)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError.invalidJSON }
        return value
    }

    func encodedData() throws -> Data {
        try JSONSerialization.data(withJSONObject: foundationValue, options: [.fragmentsAllowed, .sortedKeys])
    }

    func encodedString() throws -> String {
        String(decoding: try encodedData(), as: UTF8.self)
    }

    /// Additional limits for stored values are independent of envelope limits.
    func validate(maximumDepth: Int, maximumNodes: Int, maximumStringBytes: Int) throws {
        var nodes = 0
        try validate(depth: 1, nodes: &nodes, maximumDepth: maximumDepth,
                     maximumNodes: maximumNodes, maximumStringBytes: maximumStringBytes)
    }

    private func validate(depth: Int, nodes: inout Int, maximumDepth: Int,
                          maximumNodes: Int, maximumStringBytes: Int) throws {
        nodes += 1
        guard depth <= maximumDepth, nodes <= maximumNodes else { throw ParseError.limitExceeded }
        switch self {
        case .null, .boolean: break
        case .number(let value):
            guard value.isFinite else { throw ParseError.invalidJSON }
        case .string(let value):
            guard value.utf8.count <= maximumStringBytes else { throw ParseError.limitExceeded }
        case .array(let values):
            for value in values {
                try value.validate(depth: depth + 1, nodes: &nodes, maximumDepth: maximumDepth,
                                   maximumNodes: maximumNodes, maximumStringBytes: maximumStringBytes)
            }
        case .object(let fields):
            for (key, value) in fields {
                // Mirrors the untrusted JS snapshot rule. Even a data-only
                // toJSON field must not enter storage and later be rejected
                // by the worker while copying a successful get response.
                guard key != "toJSON" else { throw ParseError.invalidJSON }
                guard key.utf8.count <= maximumStringBytes else { throw ParseError.limitExceeded }
                try value.validate(depth: depth + 1, nodes: &nodes, maximumDepth: maximumDepth,
                                   maximumNodes: maximumNodes, maximumStringBytes: maximumStringBytes)
            }
        }
    }

    private var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .boolean(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let fields): fields.mapValues(\.foundationValue)
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        let maximumDepth: Int
        let maximumNodes: Int
        var index = 0
        var nodes = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> PluginBridgeJSON {
            nodes += 1
            guard depth <= maximumDepth, nodes <= maximumNodes else { throw ParseError.limitExceeded }
            skipWhitespace()
            guard index < bytes.count else { throw ParseError.invalidJSON }
            switch bytes[index] {
            case 110: try literal(Array("null".utf8)); return .null
            case 116: try literal(Array("true".utf8)); return .boolean(true)
            case 102: try literal(Array("false".utf8)); return .boolean(false)
            case 34: return .string(try string())
            case 91: return try array(depth: depth)
            case 123: return try object(depth: depth)
            case 45, 48...57: return .number(try number())
            default: throw ParseError.invalidJSON
            }
        }

        private mutating func literal(_ expected: [UInt8]) throws {
            guard bytes.count - index >= expected.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else { throw ParseError.invalidJSON }
            index += expected.count
        }

        private mutating func string() throws -> String {
            let start = index
            guard consume(34) else { throw ParseError.invalidJSON }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 {
                    // Foundation handles Unicode and escape validity. Only an
                    // already bounded string literal reaches this decoder.
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw ParseError.invalidJSON }
                }
                guard byte >= 32 else { throw ParseError.invalidJSON }
                if byte == 92 {
                    guard index < bytes.count else { throw ParseError.invalidJSON }
                    let escape = bytes[index]
                    index += 1
                    if escape == 117 {
                        guard bytes.count - index >= 4,
                              bytes[index..<(index + 4)].allSatisfy(Self.isHexadecimal) else {
                            throw ParseError.invalidJSON
                        }
                        index += 4
                    } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escape) {
                        throw ParseError.invalidJSON
                    }
                }
            }
            throw ParseError.invalidJSON
        }

        private mutating func number() throws -> Double {
            let start = index
            _ = consume(45)
            if consume(48) {
                // A subsequent digit is rejected by the enclosing delimiter.
            } else {
                guard index < bytes.count, (49...57).contains(bytes[index]) else { throw ParseError.invalidJSON }
                advanceDigits()
            }
            if consume(46) {
                guard index < bytes.count, Self.isDigit(bytes[index]) else { throw ParseError.invalidJSON }
                advanceDigits()
            }
            if consume(101) || consume(69) {
                if !consume(43) { _ = consume(45) }
                guard index < bytes.count, Self.isDigit(bytes[index]) else { throw ParseError.invalidJSON }
                advanceDigits()
            }
            guard let result = Double(String(decoding: bytes[start..<index], as: UTF8.self)), result.isFinite else {
                throw ParseError.invalidJSON
            }
            return result
        }

        private mutating func object(depth: Int) throws -> PluginBridgeJSON {
            _ = consume(123)
            skipWhitespace()
            var fields: [String: PluginBridgeJSON] = [:]
            if consume(125) { return .object(fields) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 34 else { throw ParseError.invalidJSON }
                let key = try string()
                guard fields[key] == nil else { throw ParseError.invalidJSON }
                skipWhitespace()
                guard consume(58) else { throw ParseError.invalidJSON }
                fields[key] = try value(depth: depth + 1)
                skipWhitespace()
                if consume(125) { return .object(fields) }
                guard consume(44) else { throw ParseError.invalidJSON }
            }
        }

        private mutating func array(depth: Int) throws -> PluginBridgeJSON {
            _ = consume(91)
            skipWhitespace()
            var values: [PluginBridgeJSON] = []
            if consume(93) { return .array(values) }
            while true {
                values.append(try value(depth: depth + 1))
                skipWhitespace()
                if consume(93) { return .array(values) }
                guard consume(44) else { throw ParseError.invalidJSON }
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private mutating func advanceDigits() {
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
        }

        private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        private static func isHexadecimal(_ byte: UInt8) -> Bool {
            isDigit(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}
