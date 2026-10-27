import Foundation

/// The full memory image of one Katana MkII patch.
///
/// A patch is 16 sections. Fourteen are 128 bytes, section 07 is 68 and
/// section 0F is 72: 1932 bytes in all. Bytes are kept by patch offset
/// (section * 128 + index) so a parameter's offset indexes straight in.
public struct PatchData: Hashable, Sendable {
    public static let sectionSizes = [128, 128, 128, 128, 128, 128, 128, 68,
                                      128, 128, 128, 128, 128, 128, 128, 72]
    /// Data bytes the amp actually stores.
    public static let byteCount = sectionSizes.reduce(0, +)
    /// Length to ask for, in address units, to read a whole patch.
    public static let requestSize = 15 * 128 + 72
    public static let nameLength = 16

    private(set) public var bytes: [UInt8]

    public init() {
        bytes = [UInt8](repeating: 0, count: 16 * 128)
    }

    /// From the 1932 bytes in amp order, as a bulk dump delivers them.
    public init?(stream: [UInt8]) {
        guard stream.count >= Self.byteCount else { return nil }
        self.init()
        var cursor = 0
        for (section, size) in Self.sectionSizes.enumerated() {
            for index in 0..<size {
                bytes[section * 128 + index] = stream[cursor] & 0x7F
                cursor += 1
            }
        }
    }

    public init?(hex: String) {
        var stream: [UInt8] = []
        stream.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            stream.append(byte)
            index = next
        }
        self.init(stream: stream)
    }

    /// FxFloorBoard's initial patch, used before an amp has been read.
    public static let initial: PatchData = PatchData(hex: KatanaCatalog.shared.defaultPatch) ?? PatchData()

    public var stream: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.byteCount)
        for (section, size) in Self.sectionSizes.enumerated() {
            out += bytes[(section * 128)..<(section * 128 + size)]
        }
        return out
    }

    public var hex: String { stream.map { String(format: "%02X", $0) }.joined() }

    public static func isStored(offset: Int) -> Bool {
        let section = offset >> 7
        return section >= 0 && section < 16 && (offset & 0x7F) < sectionSizes[section]
    }

    public subscript(offset: Int) -> UInt8 {
        get { bytes[offset] }
        set {
            guard Self.isStored(offset: offset) else { return }
            bytes[offset] = newValue & 0x7F
        }
    }

    public func raw(_ parameter: ParameterDef) -> Int {
        if parameter.size == 2 {
            return Int(bytes[parameter.offset]) * 128 + Int(bytes[parameter.offset + 1])
        }
        return Int(bytes[parameter.offset])
    }

    /// Sets a parameter and returns the bytes to send for it.
    @discardableResult
    public mutating func set(_ parameter: ParameterDef, raw: Int) -> [UInt8] {
        let value = parameter.clamp(raw)
        let encoded: [UInt8] = parameter.size == 2
            ? [UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
            : [UInt8(value & 0x7F)]
        for (i, byte) in encoded.enumerated() { self[parameter.offset + i] = byte }
        return encoded
    }

    /// Copies raw bytes in, starting at a patch offset. Bytes that land in a
    /// section's unused tail are dropped.
    public mutating func write(_ data: [UInt8], at offset: Int) {
        for (i, byte) in data.enumerated() { self[offset + i] = byte }
    }

    public var name: String {
        get {
            let raw = bytes[0..<Self.nameLength].map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : " " }
            return String(raw).trimmingCharacters(in: .whitespaces)
        }
        set {
            let ascii = newValue.unicodeScalars.map { $0.isASCII && (0x20...0x7E).contains($0.value) ? UInt8($0.value) : 0x20 }
            let padded = (ascii + [UInt8](repeating: 0x20, count: Self.nameLength)).prefix(Self.nameLength)
            for (i, byte) in padded.enumerated() { bytes[i] = byte }
        }
    }

    /// One data-set message per section: the whole patch, written to `base`
    /// (the temporary patch or a memory slot).
    public func messages(to base: KatanaAddress) -> [RolandMessage] {
        Self.sectionSizes.enumerated().map { section, size in
            RolandMessage.dataSet(base.patchOffset(section * 128),
                                  Array(bytes[(section * 128)..<(section * 128 + size)]))
        }
    }

    /// Offsets whose value differs from `other`.
    public func differences(from other: PatchData) -> [Int] {
        (0..<bytes.count).filter { bytes[$0] != other.bytes[$0] }
    }
}

extension PatchData: Codable {
    public init(from decoder: Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let patch = PatchData(hex: hex) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a patch"))
        }
        self = patch
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
