import CoreMIDI
import Foundation
import Observation
import UniformTypeIdentifiers

enum ConnectionState: Equatable {
    case offline
    case connecting(String)
    case connected(String)
    /// No amp: everything works on a local copy so the board can be explored.
    case demo

    var isLive: Bool {
        if case .connected = self { return true }
        if case .connecting = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .offline: return "Not connected"
        case .connecting(let name): return "Connecting to \(name)…"
        case .connected(let name): return name
        case .demo: return "Demo (no amp)"
        }
    }
}

struct MemorySlot: Identifiable, Hashable {
    let index: Int
    var name: String?
    var id: Int { index }
}

/// The amp as the app sees it: a live copy of the patch it is playing, its
/// nine stored patches, and the user's tone library. Every edit lands here
/// first and is then sent to the amp, coalesced so a knob being dragged does
/// not flood the Bluetooth link.
@MainActor
@Observable
final class AmpSession {
    let catalog = KatanaCatalog.shared

    private(set) var patch = PatchData.initial
    private(set) var state: ConnectionState = .offline
    private(set) var devices: [MIDIDevice] = []
    private(set) var memory: [MemorySlot] = (0..<9).map { MemorySlot(index: $0) }
    private(set) var tones: [Tone] = []
    private(set) var activity: String?
    var notice: String?

    /// Channel buttons in program-change order, as the amp numbers them.
    static let channels = ["A1", "A2", "A3", "A4", "PANEL", "B1", "B2", "B3", "B4"]

    @ObservationIgnored private let midi = MIDIConnection()
    @ObservationIgnored private let store = ToneStore.standard
    @ObservationIgnored private var assembler = DumpAssembler()
    @ObservationIgnored private var outbox: [RolandMessage] = []
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var pendingWrites: [Int: [UInt8]] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var waiter: Waiter?
    @ObservationIgnored private var exclusiveTail: Task<Void, Never>?
    @ObservationIgnored private var lastDump = Date.distantPast
    @ObservationIgnored private var autoConnect = true
    private var rememberedDevice: MIDIUniqueID? {
        get { UserDefaults.standard.object(forKey: "device") as? MIDIUniqueID }
        set { UserDefaults.standard.set(newValue, forKey: "device") }
    }

    private struct Waiter {
        let token: UUID
        let match: (DumpAssembler.Event) -> Bool
        let continuation: CheckedContinuation<DumpAssembler.Event?, Never>
    }

    init() {
        tones = store.load()
        midi.onReceive = { [weak self] in self?.handle($0) }
        midi.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        devicesChanged()
    }

    // MARK: - Connection

    func devicesChanged() {
        devices = midi.devices()
        if let connected = midi.connected, !devices.contains(where: { $0.id == connected.id }) {
            midi.disconnect()
            state = .offline
            notice = "\(connected.name) disconnected."
        }
        guard state == .offline, autoConnect else { return }
        if let device = devices.first(where: { $0.id == rememberedDevice }) ?? devices.first(where: \.looksLikeKatana) {
            Task { await connect(device) }
        }
    }

    func connect(_ device: MIDIDevice) async {
        autoConnect = true
        midi.connect(device)
        rememberedDevice = device.id
        state = .connecting(device.name)
        assembler.reset()
        await midi.send(sysex: RolandMessage.dataSet(.editorMode, [0x01]).bytes)
        if let live = await readPatch(.temporary) {
            patch = live
            state = .connected(device.name)
            await readMemoryNames()
        } else {
            state = .connected(device.name)
            notice = "\(device.name) is connected, but the amp didn't answer. Check the AIRSTEP is plugged into the Katana's USB port and the amp is on, then tap Refresh."
        }
    }

    func disconnect() {
        midi.disconnect()
        rememberedDevice = nil
        autoConnect = false
        state = .offline
    }

    func startDemo() {
        midi.disconnect()
        autoConnect = false
        state = .demo
    }

    /// Re-reads the live patch from the amp.
    func refresh() async {
        guard state.isLive else { return }
        if let live = await readPatch(.temporary) { patch = live }
    }

    // MARK: - Reading parameters

    func value(_ parameter: ParameterDef) -> Int { patch.raw(parameter) }

    func isOn(_ block: BlockDef) -> Bool {
        guard let onOff = block.onOff else { return true }
        return value(onOff) != 0
    }

    func currentType(_ block: BlockDef) -> EffectType? {
        guard let typeParameter = block.typeParameter else { return nil }
        return block.effectType(raw: value(typeParameter))
    }

    func parameters(_ block: BlockDef) -> [ParameterDef] {
        block.parameters(forType: block.typeParameter.map(value))
    }

    var chain: SignalChain { SignalChain(patch: patch) }

    var boardBlocks: [BlockDef] { chain.blockIDs(catalog).compactMap { catalog.block($0) } }

    // MARK: - Editing

    func set(_ parameter: ParameterDef, raw: Int) {
        guard patch.raw(parameter) != parameter.clamp(raw) else { return }
        let bytes = patch.set(parameter, raw: raw)
        queueWrite(bytes, at: parameter.offset)
    }

    func toggle(_ block: BlockDef) {
        guard let onOff = block.onOff else { return }
        set(onOff, raw: isOn(block) ? 0 : 1)
    }

    func setType(_ block: BlockDef, raw: Int) {
        guard let typeParameter = block.typeParameter else { return }
        set(typeParameter, raw: raw)
    }

    /// Picks red, green or yellow. The amp swaps in that variation's
    /// settings, so read them back once it has.
    func setVariation(_ block: BlockDef, raw: Int) {
        guard let variation = block.variation else { return }
        set(variation, raw: raw)
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            await refresh()
        }
    }

    /// Puts an effect type in a slot and switches the slot on.
    func place(_ type: EffectType, in block: BlockDef) {
        setType(block, raw: type.raw)
        if let onOff = block.onOff { set(onOff, raw: 1) }
    }

    func move(_ blockID: String, before target: String?) {
        var newChain = chain
        newChain.move(blockID, before: target, catalog: catalog)
        apply(newChain)
    }

    func arrange(_ order: [String]) {
        var newChain = chain
        newChain.arrange(order, catalog: catalog)
        apply(newChain)
    }

    private func apply(_ newChain: SignalChain) {
        var edited = patch
        let changed = newChain.write(into: &edited, catalog: catalog)
        patch = edited
        for offset in changed { queueWrite([edited[offset]], at: offset) }
    }

    var patchName: String {
        get { patch.name }
        set {
            patch.name = newValue
            queueWrite(Array(patch.bytes[0..<PatchData.nameLength]), at: 0)
        }
    }

    // MARK: - Channels and the amp's memory

    func selectChannel(_ index: Int) {
        guard state.isLive else { return }
        midi.sendProgramChange(UInt8(index))
        let asked = Date()
        Task {
            // In editor mode the amp sends the new patch by itself; only ask
            // if it didn't.
            try? await Task.sleep(for: .milliseconds(700))
            if lastDump < asked { await refresh() }
        }
    }

    func readMemoryNames() async {
        guard state.isLive else { return }
        for slot in 0..<memory.count {
            let base = KatanaAddress.memory(slot)
            let reply = await ask(.request(base, size: PatchData.nameLength)) { event in
                if case .bytes(let address, _) = event { return address == base }
                return false
            }
            if case .bytes(_, let data)? = reply {
                var name = PatchData()
                name.write(data, at: 0)
                memory[slot].name = name.name
            }
        }
    }

    func readMemory(_ slot: Int) async -> PatchData? {
        await readPatch(.memory(slot))
    }

    /// Plays a stored patch without switching channels.
    func audition(_ slot: Int) async {
        activity = "Loading slot \(slot + 1)…"
        defer { activity = nil }
        if let stored = await readMemory(slot) { load(stored) }
    }

    /// Writes the live patch into one of the amp's nine memories.
    func saveToMemory(_ slot: Int) {
        flushWrites()
        send(patch.messages(to: .memory(slot)))
        memory[slot].name = patch.name
        notice = "Saved \"\(patch.name)\" to slot \(slot + 1)."
    }

    /// Makes `newPatch` the sound the amp is playing.
    func load(_ newPatch: PatchData) {
        pendingWrites = [:]
        patch = newPatch
        if state.isLive { send(newPatch.messages(to: .temporary)) }
    }

    // MARK: - Library

    func saveCurrentTone(named name: String? = nil) {
        flushWrites()
        let toneName = (name?.isEmpty == false ? name! : patch.name)
        addTones([Tone(name: toneName, patch: patch, source: "Saved from the amp")])
    }

    func backUp(_ slot: Int) async {
        activity = "Backing up slot \(slot + 1)…"
        defer { activity = nil }
        guard let stored = await readMemory(slot) else {
            notice = "Slot \(slot + 1) didn't answer."
            return
        }
        addTones([Tone(name: stored.name, patch: stored, source: "Amp slot \(slot + 1)")])
    }

    func backUpAll() async {
        for slot in memory.indices { await backUp(slot) }
        notice = "Backed up all nine slots to My Tones."
    }

    func addTones(_ new: [Tone]) {
        tones.insert(contentsOf: new, at: 0)
        persist()
    }

    func update(_ tone: Tone) {
        guard let index = tones.firstIndex(where: { $0.id == tone.id }) else { return }
        tones[index] = tone
        persist()
    }

    func delete(_ ids: Set<Tone.ID>) {
        tones.removeAll { ids.contains($0.id) }
        persist()
    }

    func load(_ tone: Tone) {
        load(tone.namedPatch)
        notice = "Loaded \"\(tone.name)\"."
    }

    /// Imports a .tsl or library file; returns how many tones were added.
    @discardableResult
    func importFile(at url: URL) -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            return importData(data, fileName: url.lastPathComponent, source: url.lastPathComponent)
        } catch {
            notice = error.localizedDescription
            return 0
        }
    }

    @discardableResult
    func importData(_ data: Data, fileName: String, source: String) -> Int {
        do {
            var imported = try ToneStore.importFile(data, fileName: fileName)
            for index in imported.indices where imported[index].source.isEmpty || imported[index].source == fileName {
                imported[index].source = source
            }
            addTones(imported)
            notice = imported.count == 1 ? "Added \"\(imported[0].name)\" to My Tones." : "Added \(imported.count) tones to My Tones."
            return imported.count
        } catch {
            notice = error.localizedDescription
            return 0
        }
    }

    /// Writes tones to a .tsl in the temporary folder, for the share sheet.
    func exportTSL(_ selection: [Tone], fileName: String) -> URL? {
        let safe = fileName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe).appendingPathExtension("tsl")
        let data = TSL.write(selection.map { TSL.Entry(name: $0.name, memo: $0.memo, patch: $0.patch) }, fileName: safe)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    private func persist() {
        do { try store.save(tones) } catch { notice = "Couldn't save the library: \(error.localizedDescription)" }
    }

    // MARK: - Talking to the amp

    private func handle(_ inbound: MIDIInbound) {
        guard case .sysex(let bytes) = inbound,
              let message = RolandMessage(bytes: bytes),
              let event = assembler.handle(message) else { return }
        if let waiter, waiter.match(event) {
            self.waiter = nil
            waiter.continuation.resume(returning: event)
        }
        switch event {
        case .patch(let base, let data) where base == .temporary:
            lastDump = Date()
            patch = data
            // Edits still waiting to go out win over what the amp reported.
            for (offset, bytes) in pendingWrites { patch.write(bytes, at: offset) }
        case .bytes(let address, let data) where address.patchBase == .temporary:
            patch.write(data, at: address.offsetInPatch)
        default:
            break
        }
    }

    private func readPatch(_ base: KatanaAddress) async -> PatchData? {
        flushWrites()
        let reply = await ask(.request(base, size: PatchData.requestSize), timeout: .seconds(4)) { event in
            if case .patch(let replyBase, _) = event { return replyBase == base }
            return false
        }
        if case .patch(_, let data)? = reply { return data }
        assembler.reset()
        return nil
    }

    /// Sends a request and waits for the reply `match` accepts. Requests run
    /// one at a time so replies can't be confused.
    private func ask(_ message: RolandMessage, timeout: Duration = .seconds(2),
                     match: @escaping (DumpAssembler.Event) -> Bool) async -> DumpAssembler.Event? {
        let previous = exclusiveTail
        let task = Task { @MainActor [weak self] () -> DumpAssembler.Event? in
            await previous?.value
            guard let self, self.state.isLive else { return nil }
            await self.drainOutbox()
            return await withCheckedContinuation { continuation in
                let token = UUID()
                self.waiter = Waiter(token: token, match: match, continuation: continuation)
                Task { await self.midi.send(sysex: message.bytes) }
                Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    if let waiter = self.waiter, waiter.token == token {
                        self.waiter = nil
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        exclusiveTail = Task { _ = await task.value }
        return await task.value
    }

    private func queueWrite(_ bytes: [UInt8], at offset: Int) {
        guard state.isLive else { return }
        for (i, byte) in bytes.enumerated() { pendingWrites[offset + i] = [byte] }
        if flushTask == nil {
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(35))
                self?.flushWrites()
            }
        }
    }

    /// Turns pending byte writes into as few messages as possible: runs of
    /// neighbouring offsets in one section go out together.
    private func flushWrites() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingWrites.isEmpty else { return }
        let offsets = pendingWrites.keys.sorted()
        pendingWrites = [:]
        var messages: [RolandMessage] = []
        var runStart = offsets[0]
        var run: [UInt8] = []
        for (i, offset) in offsets.enumerated() {
            let contiguous = i > 0 && offset == offsets[i - 1] + 1 && (offset >> 7) == (runStart >> 7)
            if i > 0 && !contiguous {
                messages.append(.dataSet(KatanaAddress.temporary.patchOffset(runStart), run))
                runStart = offset
                run = []
            }
            run.append(patch[offset])
        }
        messages.append(.dataSet(KatanaAddress.temporary.patchOffset(runStart), run))
        send(messages)
    }

    private func send(_ messages: [RolandMessage]) {
        guard state.isLive else { return }
        outbox += messages
        guard !draining else { return }
        Task { await drainOutbox() }
    }

    /// Sends queued messages with a short gap, which the AIRSTEP's Bluetooth
    /// link needs to keep up.
    private func drainOutbox() async {
        guard !draining else {
            while draining { try? await Task.sleep(for: .milliseconds(10)) }
            return
        }
        draining = true
        defer { draining = false }
        while !outbox.isEmpty {
            let message = outbox.removeFirst()
            await midi.send(sysex: message.bytes)
            try? await Task.sleep(for: .milliseconds(message.data.count > 32 ? 40 : 12))
        }
    }
}
