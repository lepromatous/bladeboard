import Foundation

/// Every block, effect type and parameter of the Katana MkII (firmware 2),
/// decoded from Generated/catalog.json. See tools/build_catalog.py.
public struct KatanaCatalog: Decodable, Sendable {
    public let sectionSizes: [Int]
    public let defaultPatch: String
    public let blocks: [BlockDef]

    public static let shared: KatanaCatalog = {
        do {
            return try JSONDecoder().decode(KatanaCatalog.self, from: Data(CatalogData.json.utf8))
        } catch {
            fatalError("catalog.json does not decode: \(error)")
        }
    }()

    public func block(_ id: String) -> BlockDef? {
        blocks.first { $0.id == id }
    }

    public func block(chainID: Int) -> BlockDef? {
        blocks.first { $0.chainID == chainID }
    }

    /// Every distinct parameter, for anything that needs to walk them all.
    public var allParameters: [ParameterDef] {
        var seen = Set<Int>()
        var result: [ParameterDef] = []
        for block in blocks {
            for parameter in block.allParameters where seen.insert(parameter.offset).inserted {
                result.append(parameter)
            }
        }
        return result
    }
}

/// One block of the amp: a pedal on the board.
public struct BlockDef: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    /// The amp's own identifier for this block inside the 20-byte chain.
    public let chainID: Int
    public let onOff: ParameterDef?
    public let typeParameter: ParameterDef?
    /// Which of the three color variations (red/green/yellow) is selected.
    public let variation: ParameterDef?
    /// Pre/post-amp switch some blocks also carry.
    public let position: ParameterDef?
    /// Reverb only: what the REVERB knob drives for each color.
    public let layers: [ParameterDef]?
    public let common: [ParameterDef]
    public let advanced: [ParameterDef]
    public let types: [EffectType]

    enum CodingKeys: String, CodingKey {
        case id, name, category, chainID, variation, position, layers, common, advanced, types
        case onOff = "switch"
        case typeParameter = "type"
    }

    public func effectType(raw: Int) -> EffectType? {
        types.first { $0.raw == raw }
    }

    /// The parameters to show when the block holds the type `raw`.
    public func parameters(forType raw: Int?) -> [ParameterDef] {
        let typed = raw.flatMap { effectType(raw: $0)?.params } ?? []
        return common + typed
    }

    public var allParameters: [ParameterDef] {
        var list: [ParameterDef] = []
        for p in [onOff, typeParameter, variation, position].compactMap({ $0 }) { list.append(p) }
        list += layers ?? []
        list += common + advanced
        for type in types { list += type.params }
        return list
    }
}

public struct EffectType: Decodable, Identifiable, Hashable, Sendable {
    public let raw: Int
    public let name: String
    public let short: String
    public let category: String
    public let params: [ParameterDef]

    public var id: Int { raw }
}

public struct ParameterDef: Decodable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case range, toggle
        case enumeration = "enum"
    }

    public struct Option: Decodable, Hashable, Sendable {
        public let raw: Int
        public let label: String
    }

    /// Linear map from raw values r0...r1 to displayed values v0...v1.
    public struct Linear: Decodable, Hashable, Sendable {
        public let r0: Int
        public let r1: Int
        public let v0: Double
        public let v1: Double
        public let dec: Int
        public let unit: String

        public func value(_ raw: Int) -> Double {
            guard r1 != r0 else { return v0 }
            return v0 + Double(raw - r0) * (v1 - v0) / Double(r1 - r0)
        }
    }

    public let id: String
    public let name: String
    /// section * 128 + index inside the patch.
    public let offset: Int
    /// 1, or 2 for values stored as MSB, LSB (value = MSB * 128 + LSB).
    public let size: Int
    public let min: Int
    public let max: Int
    public let kind: Kind
    public let options: [Option]?
    public let lin: Linear?
    public let special: [Option]?

    public func clamp(_ raw: Int) -> Int {
        Swift.min(Swift.max(raw, min), max)
    }

    /// 0...1 position of a raw value, for knobs.
    public func normalized(_ raw: Int) -> Double {
        if kind == .enumeration, let options, let index = options.firstIndex(where: { $0.raw == raw }) {
            return options.count > 1 ? Double(index) / Double(options.count - 1) : 0
        }
        guard max > min else { return 0 }
        return Double(clamp(raw) - min) / Double(max - min)
    }

    /// The raw value at a 0...1 knob position.
    public func raw(normalized: Double) -> Int {
        let t = Swift.min(Swift.max(normalized, 0), 1)
        if kind == .enumeration, let options, !options.isEmpty {
            return options[Int((t * Double(options.count - 1)).rounded())].raw
        }
        return clamp(min + Int((t * Double(max - min)).rounded()))
    }

    /// The text the amp's own editor would show for `raw`.
    public func display(_ raw: Int) -> String {
        if let label = special?.first(where: { $0.raw == raw })?.label { return label }
        switch kind {
        case .toggle:
            return raw == 0 ? "Off" : "On"
        case .enumeration:
            return options?.first(where: { $0.raw == raw })?.label ?? "\(raw)"
        case .range:
            guard let lin else { return "\(raw)" }
            let value = lin.value(raw)
            var text = String(format: "%.\(lin.dec)f", value)
            if lin.v0 < 0, value > 0 { text = "+" + text }
            if text == "-0" { text = "0" }
            if lin.unit.isEmpty { return text }
            return lin.unit == "%" ? text + "%" : text + " " + lin.unit
        }
    }

    /// Whether the knob for this parameter is centred at zero (EQ gains etc.).
    public var isBipolar: Bool { (lin?.v0 ?? 0) < 0 }
}
