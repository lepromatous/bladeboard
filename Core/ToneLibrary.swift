import Foundation

/// A tone saved in the app's own library.
public struct Tone: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var memo: String
    public var patch: PatchData
    public var created: Date
    /// Where it came from: "Amp slot 3", a file name, a web page.
    public var source: String
    public var favorite: Bool

    public init(id: UUID = UUID(), name: String, memo: String = "", patch: PatchData,
                created: Date = Date(), source: String = "", favorite: Bool = false) {
        self.id = id
        self.name = name
        self.memo = memo
        self.patch = patch
        self.created = created
        self.source = source
        self.favorite = favorite
    }

    /// The patch with its stored name set to the tone's name.
    public var namedPatch: PatchData {
        var patch = patch
        patch.name = name
        return patch
    }
}

/// Saves the library as one JSON file. Small enough (2 KB a tone) that
/// rewriting it whole on every change is simpler than anything cleverer.
public struct ToneStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: ToneStore {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ToneStore(url: folder.appendingPathComponent("Tones.json"))
    }

    public func load() -> [Tone] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Tone].self, from: data)) ?? []
    }

    public func save(_ tones: [Tone]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tones).write(to: url, options: .atomic)
    }

    /// Tones from a file the user picked or downloaded: a Tone Studio .tsl,
    /// or a library export from this app.
    public static func importFile(_ data: Data, fileName: String) throws -> [Tone] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let tones = try? decoder.decode([Tone].self, from: data) {
            return tones.map { var copy = $0; copy.id = UUID(); return copy }
        }
        return try TSL.read(data).map { Tone(name: $0.name, memo: $0.memo, patch: $0.patch, source: fileName) }
    }
}
