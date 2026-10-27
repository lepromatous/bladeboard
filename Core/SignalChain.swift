import Foundation

/// The order the amp runs its blocks in.
///
/// Section 06 bytes 00-13 of a patch hold twenty block identifiers; their
/// order is the signal chain. Thirteen of them are pedals the board shows.
/// The rest (input split, second amp channel, merge, cab, USB taps, the
/// second noise suppressor) are plumbing: they keep their slots and the
/// pedals are rearranged around them.
public struct SignalChain: Equatable, Sendable {
    public static let offset = 6 * 128
    public static let length = 20

    /// Fallback when a patch holds no valid chain (all zeros, say).
    public static let factory: [UInt8] = [0x11, 0x0B, 0x0F, 0x05, 0x06, 0x0D, 0x04, 0x02, 0x0A, 0x0C,
                                          0x01, 0x07, 0x08, 0x09, 0x12, 0x00, 0x03, 0x13, 0x0E, 0x10]

    static let ampID: UInt8 = 0x02
    static let reverbID: UInt8 = 0x09

    public private(set) var ids: [UInt8]

    public init(ids: [UInt8]) {
        let valid = ids.count == Self.length && Set(ids) == Set(0..<UInt8(Self.length))
        self.ids = valid ? ids : Self.factory
    }

    public init(patch: PatchData) {
        self.init(ids: (0..<Self.length).map { patch[Self.offset + $0] })
    }

    /// Board pedals in signal order, by catalog block id.
    public func blockIDs(_ catalog: KatanaCatalog = .shared) -> [String] {
        ids.compactMap { catalog.block(chainID: Int($0))?.id }
    }

    /// Reorders the pedals to `order` (block ids). Plumbing stays put; the
    /// pedals fill the remaining slots in the new order. Blocks missing from
    /// `order` keep their relative order at the end.
    public mutating func arrange(_ order: [String], catalog: KatanaCatalog = .shared) {
        let current = blockIDs(catalog)
        var wanted = order.filter { current.contains($0) }
        wanted += current.filter { !wanted.contains($0) }
        var queue = wanted.compactMap { id in catalog.block(id).map { UInt8($0.chainID) } }
        ids = ids.map { id in
            guard catalog.block(chainID: Int(id)) != nil, !queue.isEmpty else { return id }
            return queue.removeFirst()
        }
    }

    /// Moves one pedal so it sits just before `target` (or last when nil).
    public mutating func move(_ block: String, before target: String?, catalog: KatanaCatalog = .shared) {
        var order = blockIDs(catalog)
        guard let from = order.firstIndex(of: block), block != target else { return }
        order.remove(at: from)
        if let target, let to = order.firstIndex(of: target) {
            order.insert(block, at: to)
        } else {
            order.append(block)
        }
        arrange(order, catalog: catalog)
    }

    /// Writes the chain into a patch, along with the pre/post-amp switches
    /// that older firmware reads, so both agree with the new order. Returns
    /// the offsets that changed.
    @discardableResult
    public func write(into patch: inout PatchData, catalog: KatanaCatalog = .shared) -> [Int] {
        let before = patch
        patch.write(ids, at: Self.offset)
        let amp = ids.firstIndex(of: Self.ampID) ?? 0
        let reverb = ids.firstIndex(of: Self.reverbID) ?? ids.count
        func after(_ id: Int, _ pivot: Int) -> Bool { (ids.firstIndex(of: UInt8(id)) ?? 0) > pivot }
        for blockID in ["eq1", "eq2", "pedalfx"] {
            if let block = catalog.block(blockID), let position = block.position {
                patch.set(position, raw: after(block.chainID, amp) ? 1 : 0)
            }
        }
        if let loop = catalog.block("sendreturn"), let position = loop.position {
            patch.set(position, raw: after(loop.chainID, reverb) ? 1 : 0)
        }
        return patch.differences(from: before)
    }
}
