import Foundation

/// BOSS Tone Studio `.tsl` files: JSON holding one or more patches as named
/// runs of hex bytes copied out of the amp's memory.
///
/// Where each block lands follows FxFloorBoard's TSL converter. A few blocks
/// are split across two sections; `split` gives how many bytes go to the
/// first place before the rest continue at `continuation`.
public enum TSL {
    struct Block {
        let name: String
        let offset: Int
        let length: Int
        var split: Int? = nil
        var continuation: Int? = nil
    }

    static let blocks: [Block] = [
        Block(name: "PatchName", offset: 0x000, length: 16),
        Block(name: "Patch_0", offset: 0x010, length: 72),
        Block(name: "Eq(2)", offset: 0x060, length: 24),
        Block(name: "Fx(1)", offset: 0x080, length: 225, split: 128, continuation: 0x100),
        Block(name: "Fx(2)", offset: 0x180, length: 225, split: 128, continuation: 0x200),
        Block(name: "Delay(1)", offset: 0x280, length: 26),
        Block(name: "Delay(2)", offset: 0x2A0, length: 26),
        Block(name: "Patch_1", offset: 0x2C0, length: 91, split: 64, continuation: 0x300),
        Block(name: "Patch_2", offset: 0x320, length: 36),
        Block(name: "Status", offset: 0x350, length: 18),
        Block(name: "KnobAsgn", offset: 0x380, length: 34),
        Block(name: "ExpPedalAsgn", offset: 0x400, length: 34),
        Block(name: "ExpPedalAsgnMinMax", offset: 0x430, length: 78),
        Block(name: "GafcExp1Asgn", offset: 0x480, length: 34),
        Block(name: "GafcExp1AsgnMinMax", offset: 0x4B0, length: 78),
        Block(name: "GafcExp2Asgn", offset: 0x500, length: 34),
        Block(name: "GafcExp2AsgnMinMax", offset: 0x530, length: 78),
        Block(name: "FsAsgn", offset: 0x788, length: 2),
        Block(name: "Patch_Mk2V2", offset: 0x790, length: 22),
        Block(name: "Contour(1)", offset: 0x7AE, length: 2),
        Block(name: "Contour(2)", offset: 0x7B6, length: 2),
        Block(name: "Contour(3)", offset: 0x7BE, length: 2),
    ]

    public struct Entry: Sendable {
        public var name: String
        public var memo: String
        public var patch: PatchData
    }

    public enum Failure: LocalizedError {
        case notJSON
        case notKatana(String)
        case gen3
        case empty

        public var errorDescription: String? {
            switch self {
            case .notJSON: return "This isn't a Tone Studio file."
            case .notKatana(let device): return "This file is for \(device), not a Katana MkII."
            case .gen3: return "This is a Katana Gen 3 patch. Only MkII (and MkI) patches can be loaded on a MkII."
            case .empty: return "The file holds no patches."
            }
        }
    }

    /// Reads every patch in a file. Each one starts from `base`, so blocks a
    /// file leaves out keep sensible values.
    public static func read(_ data: Data, base: PatchData = .initial) throws -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notJSON }
        let device = root["device"] as? String ?? ""
        if device.localizedCaseInsensitiveContains("gen3") || device.localizedCaseInsensitiveContains("gen 3") { throw Failure.gen3 }
        if !device.isEmpty, !device.localizedCaseInsensitiveContains("katana") { throw Failure.notKatana(device) }

        let groups = root["data"] as? [Any] ?? []
        var entries: [Entry] = []
        for group in groups {
            let items = (group as? [Any]) ?? [group]
            for case let item as [String: Any] in items {
                guard let paramSet = item["paramSet"] as? [String: Any] else { continue }
                if paramSet.keys.contains(where: { $0.hasPrefix("PATCH%") }) { throw Failure.gen3 }
                var patch = base
                for block in blocks {
                    guard let values = paramSet["UserPatch%\(block.name)"] as? [Any] else { continue }
                    let bytes = values.compactMap(byte)
                    apply(bytes, block, to: &patch)
                }
                let memo = item["memo"] as? String ?? ""
                let name = patch.name.isEmpty ? (root["name"] as? String ?? "Imported") : patch.name
                entries.append(Entry(name: name, memo: memo, patch: patch))
            }
        }
        guard !entries.isEmpty else { throw Failure.empty }
        return entries
    }

    /// A `.tsl` file Tone Studio (and Katana Librarian) can import.
    public static func write(_ entries: [Entry], fileName: String) -> Data {
        let patches: [[String: Any]] = entries.map { entry in
            var patch = entry.patch
            patch.name = entry.name
            var paramSet: [String: [String]] = [:]
            for block in blocks {
                paramSet["UserPatch%\(block.name)"] = extract(block, from: patch).map { String(format: "%02X", $0) }
            }
            return ["memo": entry.memo, "paramSet": paramSet]
        }
        let root: [String: Any] = ["name": fileName, "formatRev": "0002", "device": "KATANA MkII", "data": [patches]]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func apply(_ bytes: [UInt8], _ block: Block, to patch: inout PatchData) {
        guard let split = block.split, let continuation = block.continuation, bytes.count > split else {
            patch.write(bytes, at: block.offset)
            return
        }
        patch.write(Array(bytes[..<split]), at: block.offset)
        patch.write(Array(bytes[split...]), at: continuation)
    }

    static func extract(_ block: Block, from patch: PatchData) -> [UInt8] {
        let firstLength = block.split ?? block.length
        var out = (0..<firstLength).map { patch[block.offset + $0] }
        if let continuation = block.continuation {
            out += (0..<(block.length - firstLength)).map { patch[continuation + $0] }
        }
        return out
    }

    private static func byte(_ value: Any) -> UInt8? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
            return UInt8(trimmed, radix: 16)
        }
        if let number = value as? NSNumber { return UInt8(clamping: number.intValue) }
        return nil
    }
}
