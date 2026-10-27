import CoreMIDI
import Foundation
import os

/// A MIDI device the amp can be reached through: the AIRSTEP Kat over
/// Bluetooth, or the Katana itself over a USB cable.
struct MIDIDevice: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
    let source: MIDIEndpointRef
    let destination: MIDIEndpointRef

    /// Names that are almost certainly the amp or its Bluetooth bridge.
    var looksLikeKatana: Bool {
        let lower = name.lowercased()
        return lower.contains("airstep") || lower.contains("katana") || lower.contains("kat")
    }
}

/// CoreMIDI plumbing: finds devices, listens to one, sends SysEx to it.
///
/// Receiving runs on CoreMIDI's own thread; everything handed to `onReceive`
/// and `onDevicesChanged` is delivered on the main queue.
final class MIDIConnection {
    var onReceive: (MIDIInbound) -> Void = { _ in }
    var onDevicesChanged: () -> Void = {}

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private(set) var connected: MIDIDevice?
    private let decoder = OSAllocatedUnfairLock(initialState: UMPDecoder())
    private let log = Logger(subsystem: "KatanaBoard", category: "MIDI")

    init() {
        MIDIClientCreateWithBlock("KatanaBoard" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.onDevicesChanged() }
            }
        }
        MIDIInputPortCreateWithProtocol(client, "KatanaBoard In" as CFString, ._1_0, &inputPort) { [weak self] list, _ in
            self?.receive(list)
        }
        MIDIOutputPortCreate(client, "KatanaBoard Out" as CFString, &outputPort)
    }

    /// Devices that can both send and receive, which is what the amp needs.
    func devices() -> [MIDIDevice] {
        var sources: [MIDIEntityRef: MIDIEndpointRef] = [:]
        var sourcesByName: [String: MIDIEndpointRef] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            var entity = MIDIEntityRef()
            MIDIEndpointGetEntity(endpoint, &entity)
            if entity != 0 { sources[entity] = endpoint }
            sourcesByName[Self.name(of: endpoint)] = endpoint
        }
        var found: [MIDIDevice] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            var entity = MIDIEntityRef()
            MIDIEndpointGetEntity(destination, &entity)
            let name = Self.name(of: destination)
            guard let source = (entity != 0 ? sources[entity] : nil) ?? sourcesByName[name] else { continue }
            var unique: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &unique)
            found.append(MIDIDevice(id: unique, name: name, source: source, destination: destination))
        }
        return found.sorted { ($0.looksLikeKatana ? 0 : 1, $0.name) < ($1.looksLikeKatana ? 0 : 1, $1.name) }
    }

    func connect(_ device: MIDIDevice) {
        disconnect()
        MIDIPortConnectSource(inputPort, device.source, nil)
        connected = device
        decoder.withLock { $0 = UMPDecoder() }
        log.info("Connected to \(device.name, privacy: .public)")
    }

    func disconnect() {
        if let connected { MIDIPortDisconnectSource(inputPort, connected.source) }
        connected = nil
    }

    /// Sends one complete SysEx message and waits until CoreMIDI has sent it.
    func send(sysex bytes: [UInt8]) async {
        guard let destination = connected?.destination, !bytes.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let job = SysexJob(bytes: bytes, continuation: continuation)
            job.request.pointee = MIDISysexSendRequest(
                destination: destination,
                data: UnsafePointer(job.buffer),
                bytesToSend: UInt32(bytes.count),
                complete: false,
                reserved: (0, 0, 0),
                completionProc: { request in
                    guard let context = request.pointee.completionRefCon else { return }
                    Unmanaged<SysexJob>.fromOpaque(context).takeRetainedValue().finish()
                },
                completionRefCon: Unmanaged.passRetained(job).toOpaque())
            if MIDISendSysex(job.request) != noErr {
                Unmanaged<SysexJob>.fromOpaque(job.request.pointee.completionRefCon!).takeRetainedValue().finish()
            }
        }
    }

    /// Program change on `channel` (0-based): how the amp switches channels.
    func sendProgramChange(_ program: UInt8, channel: UInt8 = 0) {
        sendWord(0x2000_0000 | (UInt32(0xC0 | (channel & 0x0F)) << 16) | (UInt32(program & 0x7F) << 8))
    }

    func sendControlChange(_ control: UInt8, value: UInt8, channel: UInt8 = 0) {
        sendWord(0x2000_0000 | (UInt32(0xB0 | (channel & 0x0F)) << 16) | (UInt32(control & 0x7F) << 8) | UInt32(value & 0x7F))
    }

    private func sendWord(_ word: UInt32) {
        guard let destination = connected?.destination else { return }
        var list = MIDIEventList()
        withUnsafeMutablePointer(to: &list) { pointer in
            let packet = MIDIEventListInit(pointer, ._1_0)
            var value = word
            _ = MIDIEventListAdd(pointer, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &value)
            MIDISendEventList(outputPort, destination, pointer)
        }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        var words: [UInt32] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                for index in 0..<min(count, raw.count / 4) {
                    words.append(raw.load(fromByteOffset: index * 4, as: UInt32.self))
                }
            }
        }
        let received = words
        let messages = decoder.withLock { $0.decode(received) }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            messages.forEach { self?.onReceive($0) }
        }
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        return (name?.takeRetainedValue() as String?) ?? "MIDI Device"
    }
}

/// Keeps a SysEx buffer and its request alive until CoreMIDI is done with them.
private final class SysexJob {
    let buffer: UnsafeMutablePointer<UInt8>
    let request: UnsafeMutablePointer<MIDISysexSendRequest>
    private let continuation: CheckedContinuation<Void, Never>

    init(bytes: [UInt8], continuation: CheckedContinuation<Void, Never>) {
        buffer = .allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        request = .allocate(capacity: 1)
        self.continuation = continuation
    }

    func finish() {
        continuation.resume()
    }

    deinit {
        buffer.deallocate()
        request.deallocate()
    }
}
