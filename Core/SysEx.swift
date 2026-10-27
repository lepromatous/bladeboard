import Foundation

/// A four-byte Roland address. Each byte carries 7 bits, so the address is
/// also a 28-bit number, which is how ranges and lengths are computed.
public struct KatanaAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        bytes = [a & 0x7F, b & 0x7F, c & 0x7F, d & 0x7F]
    }

    public init(value: Int) {
        self.init(UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
                  UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F))
    }

    public init?(_ slice: ArraySlice<UInt8>) {
        guard slice.count == 4 else { return nil }
        let b = Array(slice)
        self.init(b[0], b[1], b[2], b[3])
    }

    public var value: Int {
        (Int(bytes[0]) << 21) | (Int(bytes[1]) << 14) | (Int(bytes[2]) << 7) | Int(bytes[3])
    }

    /// The patch the amp is playing right now.
    public static let temporary = KatanaAddress(0x60, 0x00, 0x00, 0x00)

    /// One of the nine stored patches, 0...8.
    public static func memory(_ slot: Int) -> KatanaAddress {
        KatanaAddress(0x10, UInt8(slot), 0x00, 0x00)
    }

    /// The editor-mode switch. With it on, the amp reports knob turns and
    /// channel changes back to us.
    public static let editorMode = KatanaAddress(0x7F, 0x00, 0x00, 0x01)

    /// `offset` is a patch offset: section * 128 + index.
    public func patchOffset(_ offset: Int) -> KatanaAddress {
        KatanaAddress(bytes[0], bytes[1], UInt8(offset >> 7), UInt8(offset & 0x7F))
    }

    /// The first two bytes say which patch an address belongs to.
    public var patchBase: KatanaAddress { KatanaAddress(bytes[0], bytes[1], 0, 0) }

    /// The patch offset (section * 128 + index) this address points at.
    public var offsetInPatch: Int { (Int(bytes[2]) << 7) | Int(bytes[3]) }

    public var description: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

public enum RolandCommand: UInt8, Sendable {
    case request = 0x11
    case dataSet = 0x12
}

/// One Roland exclusive message to or from the Katana.
///
///     F0 41 00 00 00 00 33 <cmd> <address:4> <data...> <checksum> F7
public struct RolandMessage: Equatable, Sendable {
    public var command: RolandCommand
    public var address: KatanaAddress
    public var data: [UInt8]

    public init(command: RolandCommand, address: KatanaAddress, data: [UInt8]) {
        self.command = command
        self.address = address
        self.data = data
    }

    public static let header: [UInt8] = [0xF0, 0x41, 0x00, 0x00, 0x00, 0x00, 0x33]

    /// Roland's checksum: whatever brings address + data to a multiple of 128.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        let sum = bytes.reduce(0) { ($0 + Int($1)) & 0x7F }
        return UInt8((128 - sum) & 0x7F)
    }

    public static func dataSet(_ address: KatanaAddress, _ data: [UInt8]) -> RolandMessage {
        RolandMessage(command: .dataSet, address: address, data: data)
    }

    /// Asks the amp for `size` bytes starting at `address`.
    public static func request(_ address: KatanaAddress, size: Int) -> RolandMessage {
        RolandMessage(command: .request, address: address, data: KatanaAddress(value: size).bytes)
    }

    public var bytes: [UInt8] {
        let body = address.bytes + data
        return Self.header + [command.rawValue] + body + [Self.checksum(body), 0xF7]
    }

    /// Parses a complete F0...F7 message. Returns nil for anything that is not
    /// a well-formed Katana message, including a bad checksum.
    public init?(bytes: [UInt8]) {
        guard bytes.count >= 15, bytes.last == 0xF7,
              Array(bytes.prefix(7)) == Self.header,
              let command = RolandCommand(rawValue: bytes[7]),
              let address = KatanaAddress(bytes[8..<12]) else { return nil }
        let data = Array(bytes[12..<(bytes.count - 2)])
        guard Self.checksum(address.bytes + data) == bytes[bytes.count - 2] else { return nil }
        self.init(command: command, address: address, data: data)
    }
}

/// Universal identity request; the Katana answers with its family code.
public enum IdentityRequest {
    public static let bytes: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]

    /// True for an identity reply from a Roland 0x33 device (the Katana).
    public static func isKatanaReply(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 8 && bytes[1] == 0x7E && bytes[3] == 0x06 && bytes[4] == 0x02
            && bytes[5] == 0x41 && bytes[6] == 0x33
    }
}
