import Foundation

/// What arrives from the amp, decoded from Universal MIDI Packets.
public enum MIDIInbound: Equatable, Sendable {
    case sysex([UInt8])
    case programChange(channel: UInt8, program: UInt8)
    case controlChange(channel: UInt8, control: UInt8, value: UInt8)
}

/// Turns the UMP words CoreMIDI delivers (MIDI 1.0 protocol) back into
/// whole messages. SysEx arrives as 7-bit SysEx packets of up to six bytes
/// each, flagged complete/start/continue/end; this stitches them together.
public struct UMPDecoder: Sendable {
    private var sysex: [UInt8] = []
    private var collecting = false

    public init() {}

    public mutating func decode(_ words: [UInt32]) -> [MIDIInbound] {
        var out: [MIDIInbound] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            let type = Int(word >> 28)
            let length = Self.wordCount(type)
            defer { i += length }
            switch type {
            case 0x2:
                let status = UInt8((word >> 16) & 0xF0)
                let channel = UInt8((word >> 16) & 0x0F)
                let data1 = UInt8((word >> 8) & 0x7F)
                let data2 = UInt8(word & 0x7F)
                if status == 0xC0 { out.append(.programChange(channel: channel, program: data1)) }
                if status == 0xB0 { out.append(.controlChange(channel: channel, control: data1, value: data2)) }
            case 0x3:
                guard i + 1 < words.count else { break }
                let second = words[i + 1]
                let status = (word >> 20) & 0xF
                let count = Int((word >> 16) & 0xF)
                let all: [UInt8] = [UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF),
                                    UInt8(second >> 24), UInt8((second >> 16) & 0xFF),
                                    UInt8((second >> 8) & 0xFF), UInt8(second & 0xFF)]
                let bytes = Array(all.prefix(Swift.min(count, 6)))
                switch status {
                case 0:
                    out.append(.sysex([0xF0] + bytes + [0xF7]))
                    collecting = false
                case 1:
                    sysex = bytes
                    collecting = true
                case 2:
                    if collecting { sysex += bytes }
                case 3:
                    if collecting {
                        out.append(.sysex([0xF0] + sysex + bytes + [0xF7]))
                    }
                    collecting = false
                    sysex = []
                default:
                    break
                }
            default:
                break
            }
        }
        return out
    }

    static func wordCount(_ type: Int) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    /// Encodes SysEx as UMP 7-bit SysEx packets: the inverse of decode, used
    /// by tests and anything that sends with MIDISendEventList.
    public static func encodeSysex(_ message: [UInt8], group: UInt32 = 0) -> [UInt32] {
        var payload = message
        if payload.first == 0xF0 { payload.removeFirst() }
        if payload.last == 0xF7 { payload.removeLast() }
        let chunks = stride(from: 0, to: Swift.max(payload.count, 1), by: 6).map {
            Array(payload[$0..<Swift.min($0 + 6, payload.count)])
        }
        var words: [UInt32] = []
        for (index, chunk) in chunks.enumerated() {
            let status: UInt32
            if chunks.count == 1 { status = 0 } else if index == 0 { status = 1 } else if index == chunks.count - 1 { status = 3 } else { status = 2 }
            var b = chunk + [UInt8](repeating: 0, count: 6 - chunk.count)
            if b.count > 6 { b = Array(b.prefix(6)) }
            words.append((0x3 << 28) | (group << 24) | (status << 20) | (UInt32(chunk.count) << 16) | (UInt32(b[0]) << 8) | UInt32(b[1]))
            words.append((UInt32(b[2]) << 24) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 8) | UInt32(b[5]))
        }
        return words
    }
}

/// Reassembles what the amp sends back into patches and parameter changes.
///
/// A patch dump arrives as several data-set messages (about 241 bytes each)
/// whose data, laid end to end, is the 1932-byte patch in section order.
/// They come in order, so they are appended as they arrive. Anything small
/// is a parameter report and applies by address.
public struct DumpAssembler: Sendable {
    public enum Event: Equatable, Sendable {
        /// A whole patch. `base` is the temporary patch or a memory slot.
        case patch(base: KatanaAddress, PatchData)
        /// A few bytes changed at `address` (a knob was turned on the amp).
        case bytes(address: KatanaAddress, [UInt8])
    }

    /// Larger than any single parameter, smaller than a dump chunk.
    static let dumpThreshold = 64

    private var base: KatanaAddress?
    private var buffer: [UInt8] = []
    private let expected = PatchData.byteCount

    public init() {}

    public var isCollecting: Bool { base != nil }

    public mutating func reset() {
        base = nil
        buffer = []
    }

    public mutating func handle(_ message: RolandMessage) -> Event? {
        guard message.command == .dataSet else { return nil }
        let patchBase = message.address.patchBase

        if let base, base == patchBase {
            buffer += message.data
            if buffer.count >= expected {
                defer { reset() }
                return PatchData(stream: buffer).map { .patch(base: base, $0) }
            }
            return nil
        }

        if message.address.offsetInPatch == 0, message.data.count > Self.dumpThreshold {
            base = patchBase
            buffer = message.data
            if buffer.count >= expected {
                defer { reset() }
                return PatchData(stream: buffer).map { .patch(base: patchBase, $0) }
            }
            return nil
        }

        return .bytes(address: message.address, message.data)
    }
}
