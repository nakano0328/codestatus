import Foundation

/// Fork addition: just enough of Chromium's IndexedDB value format to read the
/// Claude desktop app's own cache of its cloud sessions. See
/// ``CloudSessionReader``.
///
/// A large IndexedDB value is written to a blob file as Blink's value wrapper
/// (`FF 11`), optionally Snappy-compressed (`02`), around Blink's envelope
/// (`FF <version>`, `FE` + a 12-byte trailer offset) around V8's structured
/// clone format (`FF <version>`, then tagged values).
///
/// Everything here is bounds-checked and depth-limited, and every failure is a
/// thrown error rather than a trap: the input is another application's private
/// file, which can change shape with any update and can be caught mid-write.
enum ChromiumValueDecoding {

    enum DecodeError: Error, Equatable {
        case truncated
        case malformed(String)
        case tooLarge
        case unsupportedTag(UInt8)
        case tooDeep
    }

    /// The decompressed size we refuse to go past. The cache is well under a
    /// megabyte; anything claiming more is not the file we are looking for.
    static let maxDecompressedBytes = 32 * 1024 * 1024

    // MARK: - Blob file

    /// Unwraps one IndexedDB blob file into a JavaScript value.
    static func decodeIndexedDBBlob(_ data: [UInt8]) throws -> JSValue {
        guard data.count >= 3, data[0] == 0xFF, data[1] == 0x11 else {
            throw DecodeError.malformed("not a Blink value wrapper")
        }
        let payload: [UInt8]
        switch data[2] {
        case 0x02: payload = try snappyDecompress(Array(data[3...]))
        case 0x01: throw DecodeError.malformed("refers to another blob")
        default: payload = Array(data[3...])
        }
        var reader = ByteReader(payload)
        // Blink's envelope: its version, then an optional trailer offset.
        guard try reader.byte() == 0xFF else { throw DecodeError.malformed("no Blink version") }
        _ = try reader.varint()
        if reader.peek() == 0xFE {
            try reader.skip(1 + 8 + 4)
        }
        var decoder = V8Decoder(reader: reader)
        return try decoder.value(depth: 0)
    }

    // MARK: - Snappy

    /// Raw Snappy (not the framed format): a varint length, then literals and
    /// back-references.
    static func snappyDecompress(_ input: [UInt8]) throws -> [UInt8] {
        var reader = ByteReader(input)
        let expected = try reader.varint()
        guard expected <= UInt64(maxDecompressedBytes) else { throw DecodeError.tooLarge }
        var out: [UInt8] = []
        out.reserveCapacity(Int(expected))

        while !reader.isAtEnd {
            let tag = try reader.byte()
            switch tag & 0x03 {
            case 0x00:
                var length = Int(tag >> 2)
                if length >= 60 {
                    let extra = length - 59
                    length = 0
                    for shift in 0..<extra { length |= Int(try reader.byte()) << (8 * shift) }
                }
                length += 1
                out.append(contentsOf: try reader.bytes(length))
            case 0x01:
                let length = Int((tag >> 2) & 0x07) + 4
                let offset = (Int(tag >> 5) << 8) | Int(try reader.byte())
                try copy(&out, offset: offset, length: length)
            case 0x02:
                let length = Int(tag >> 2) + 1
                let offset = Int(try reader.byte()) | Int(try reader.byte()) << 8
                try copy(&out, offset: offset, length: length)
            default:
                let length = Int(tag >> 2) + 1
                var offset = 0
                for shift in 0..<4 { offset |= Int(try reader.byte()) << (8 * shift) }
                try copy(&out, offset: offset, length: length)
            }
            guard out.count <= Int(expected) else { throw DecodeError.malformed("snappy overran its length") }
        }
        guard out.count == Int(expected) else { throw DecodeError.truncated }
        return out
    }

    private static func copy(_ out: inout [UInt8], offset: Int, length: Int) throws {
        guard offset > 0, offset <= out.count else { throw DecodeError.malformed("snappy offset") }
        let start = out.count - offset
        // Byte by byte: a copy may overlap what it is producing.
        for index in 0..<length { out.append(out[start + index]) }
    }
}

/// A JavaScript value, as far as this reader cares. Anything it does not need
/// (array buffers, dates, regexps, errors) collapses to ``other``.
indirect enum JSValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSValue])
    case object([String: JSValue])
    case other

    subscript(key: String) -> JSValue? {
        if case .object(let dictionary) = self { return dictionary[key] }
        return nil
    }

    subscript(index: Int) -> JSValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        if case .object(let dictionary) = self { return dictionary[String(index)] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Elements of an array, or of an object used as one (sparse arrays and
    /// plain objects with integer keys both come out as objects).
    var elements: [JSValue] {
        switch self {
        case .array(let array): return array
        case .object(let dictionary):
            return dictionary.keys.compactMap(Int.init).sorted().compactMap { dictionary[String($0)] }
        default: return []
        }
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    func peek() -> UInt8? { isAtEnd ? nil : bytes[offset] }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw ChromiumValueDecoding.DecodeError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count - offset else { throw ChromiumValueDecoding.DecodeError.truncated }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func skip(_ count: Int) throws { _ = try bytes(count) }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let next = try byte()
            guard shift < 64 else { throw ChromiumValueDecoding.DecodeError.malformed("varint") }
            result |= UInt64(next & 0x7F) << shift
            if next < 0x80 { return result }
            shift += 7
        }
    }

    mutating func double() throws -> Double {
        let raw = try bytes(8)
        var bits: UInt64 = 0
        for (index, byte) in raw.enumerated() { bits |= UInt64(byte) << (8 * UInt64(index)) }
        return Double(bitPattern: bits)
    }
}

/// V8's `ValueDeserializer`, for the tags a JSON-shaped object graph uses.
struct V8Decoder {
    var reader: ByteReader
    /// Objects in the order they were opened, for `^` back-references.
    private var objects: [JSValue] = []

    static let maxDepth = 64

    init(reader: ByteReader) { self.reader = reader }

    mutating func value(depth: Int) throws -> JSValue {
        guard depth <= Self.maxDepth else { throw ChromiumValueDecoding.DecodeError.tooDeep }
        var tag = try reader.byte()
        while tag == 0x00 { tag = try reader.byte() }    // padding

        switch tag {
        case 0xFF:                                       // version header
            _ = try reader.varint()
            return try value(depth: depth)
        case UInt8(ascii: "_"), UInt8(ascii: "0"), UInt8(ascii: "-"):
            return .null
        case UInt8(ascii: "T"): return .bool(true)
        case UInt8(ascii: "F"): return .bool(false)
        // Wrapper objects (`new Boolean`, `new Number`, `new String`) and dates
        // are objects to V8 and take a slot in the back-reference table.
        case UInt8(ascii: "y"): return fill(reserve(), .bool(true))
        case UInt8(ascii: "x"): return fill(reserve(), .bool(false))
        case UInt8(ascii: "I"):
            let raw = try reader.varint()
            let decoded = Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
            return .number(Double(decoded))
        case UInt8(ascii: "U"):
            return .number(Double(try reader.varint()))
        case UInt8(ascii: "N"):
            return .number(try reader.double())
        case UInt8(ascii: "n"):
            let slot = reserve()
            return fill(slot, .number(try reader.double()))
        case UInt8(ascii: "D"):
            _ = reserve()
            _ = try reader.double()
            return .other
        case UInt8(ascii: "\""):
            let length = Int(try reader.varint())
            return .string(String(decoding: try reader.bytes(length).map { UInt16($0) }, as: UTF16.self))
        case UInt8(ascii: "c"):
            let length = Int(try reader.varint())
            guard length % 2 == 0 else { throw ChromiumValueDecoding.DecodeError.malformed("two-byte string") }
            let raw = try reader.bytes(length)
            var units: [UInt16] = []
            units.reserveCapacity(length / 2)
            var index = raw.startIndex
            while index < raw.endIndex {
                units.append(UInt16(raw[index]) | UInt16(raw[index + 1]) << 8)
                index += 2
            }
            return .string(String(decoding: units, as: UTF16.self))
        case UInt8(ascii: "S"):
            let length = Int(try reader.varint())
            return .string(String(decoding: try reader.bytes(length), as: UTF8.self))
        case UInt8(ascii: "s"):                          // String object
            let slot = reserve()
            return fill(slot, try value(depth: depth + 1))
        case UInt8(ascii: "o"):
            let slot = reserve()
            var dictionary: [String: JSValue] = [:]
            while reader.peek() != UInt8(ascii: "{") {
                let key = try value(depth: depth + 1)
                dictionary[Self.key(key)] = try value(depth: depth + 1)
            }
            try reader.skip(1)
            _ = try reader.varint()
            return fill(slot, .object(dictionary))
        case UInt8(ascii: "A"):
            let slot = reserve()
            let count = Int(try reader.varint())
            guard count <= 1_000_000 else { throw ChromiumValueDecoding.DecodeError.tooLarge }
            var array: [JSValue] = []
            for _ in 0..<count { array.append(try value(depth: depth + 1)) }
            // Extra named properties on an array, which we drop.
            while reader.peek() != UInt8(ascii: "$") {
                _ = try value(depth: depth + 1)
                _ = try value(depth: depth + 1)
            }
            try reader.skip(1)
            _ = try reader.varint()
            _ = try reader.varint()
            return fill(slot, .array(array))
        case UInt8(ascii: "a"):
            let slot = reserve()
            _ = try reader.varint()
            var dictionary: [String: JSValue] = [:]
            while reader.peek() != UInt8(ascii: "@") {
                let key = try value(depth: depth + 1)
                dictionary[Self.key(key)] = try value(depth: depth + 1)
            }
            try reader.skip(1)
            _ = try reader.varint()
            _ = try reader.varint()
            return fill(slot, .object(dictionary))
        case UInt8(ascii: ";"):                          // Map
            let slot = reserve()
            var dictionary: [String: JSValue] = [:]
            while reader.peek() != UInt8(ascii: ":") {
                let key = try value(depth: depth + 1)
                dictionary[Self.key(key)] = try value(depth: depth + 1)
            }
            try reader.skip(1)
            _ = try reader.varint()
            return fill(slot, .object(dictionary))
        case UInt8(ascii: "'"):                          // Set
            let slot = reserve()
            var array: [JSValue] = []
            while reader.peek() != UInt8(ascii: ",") { array.append(try value(depth: depth + 1)) }
            try reader.skip(1)
            _ = try reader.varint()
            return fill(slot, .array(array))
        case UInt8(ascii: "^"):
            let id = Int(try reader.varint())
            guard objects.indices.contains(id) else { throw ChromiumValueDecoding.DecodeError.malformed("reference") }
            return objects[id]
        case UInt8(ascii: "R"):                          // RegExp
            _ = reserve()
            _ = try value(depth: depth + 1)
            _ = try reader.varint()
            return .other
        case UInt8(ascii: "r"):                          // Error
            _ = reserve()
            while true {
                let sub = try reader.byte()
                switch sub {
                case UInt8(ascii: "."): return .other
                case UInt8(ascii: "m"), UInt8(ascii: "s"), UInt8(ascii: "c"):
                    _ = try value(depth: depth + 1)
                default:
                    continue                             // prototype tags carry no payload
                }
            }
        case UInt8(ascii: "B"):                          // ArrayBuffer
            let slot = reserve()
            try reader.skip(Int(try reader.varint()))
            // A typed array over it follows as a view.
            if reader.peek() == UInt8(ascii: "V") {
                try reader.skip(1)
                _ = try reader.byte()
                _ = try reader.varint()
                _ = try reader.varint()
                _ = try reader.varint()
                _ = reserve()
            }
            return fill(slot, .other)
        case UInt8(ascii: "Z"):                          // BigInt
            let bitfield = try reader.varint()
            try reader.skip(Int(bitfield / 2))
            return .other
        default:
            throw ChromiumValueDecoding.DecodeError.unsupportedTag(tag)
        }
    }

    private static func key(_ value: JSValue) -> String {
        switch value {
        case .string(let string): return string
        case .number(let number) where number == number.rounded() && abs(number) < 1e15:
            return String(Int64(number))
        case .number(let number): return String(number)
        case .bool(let bool): return String(bool)
        default: return ""
        }
    }

    private mutating func reserve() -> Int {
        objects.append(.other)
        return objects.count - 1
    }

    private mutating func fill(_ slot: Int, _ value: JSValue) -> JSValue {
        objects[slot] = value
        return value
    }
}
