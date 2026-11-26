import CryptoKit
import Foundation

/// Any JSON, kept as it was read. A RAW layer's settings are saved as plain JSON objects and read back over today's
/// defaults (`decoded(over:)`): a control Camera Raw has gained since the project was saved takes its default and one
/// it has lost is ignored, where decoding the settings directly would refuse them all for the one member.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// What `value` encodes to.
    init<Value: Encodable>(_ value: Value) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// This laid over `defaults`: an object keeps the members of `defaults` it has none of its own for, all the way
    /// down. Anything else is itself.
    func over(_ defaults: JSONValue) -> JSONValue {
        guard case .object(let mine) = self, case .object(var merged) = defaults else { return self }
        for (key, value) in mine { merged[key] = merged[key].map { value.over($0) } ?? value }
        return .object(merged)
    }

    /// This read as a `Value`, over what `defaults` encodes to. Nil when it still can't be read as one.
    func decoded<Value: Codable>(over defaults: Value) -> Value? {
        guard let base = try? JSONValue(defaults), let data = try? JSONEncoder().encode(over(base)) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}

/// A RAW layer's recipe as a project keeps it (`RawOrigin`): where the file is, and what it is developed with. The
/// file stays where it is and is never written, by the app or through this: the bookmark is read-only, as a movie
/// layer's is. The layer's pixels are saved as any layer's are, so a project opens the same with the file gone;
/// with it there, Camera Raw opens on the layer with every control where it was left and develops from the file.
nonisolated struct RawLink: Codable, Equatable, Sendable {
    /// A read-only sandbox bookmark of the RAW file.
    var bookmark: Data
    /// The file's length and `RawOrigin.digest(of:)` its bytes. Another file found where the bookmark leads isn't
    /// developed in the layer's place.
    var byteCount: Int
    var digest: String
    /// The file's type, which tells the engine whose format the bytes are.
    var type: String?
    /// The layer's size in pixels. Pixels of another size aren't what this recipe made.
    var width: Int
    var height: Int
    /// `RawDevelopSettings`, and `CameraRawSettings` where Camera Raw's sliders were moved, as JSON objects.
    var develop: JSONValue
    var cameraRaw: JSONValue?
    /// What the sliders' grain was drawn with.
    var seed: UInt32

    /// What a layer of `width` × `height` made from `origin` saves. Nil when no bookmark could be made of the file:
    /// the layer is then saved as its pixels alone, as it was before projects kept recipes.
    init?(_ origin: RawOrigin, width: Int, height: Int) {
        guard let bookmark = origin.bookmark, let develop = try? JSONValue(origin.settings) else { return nil }
        var cameraRaw: JSONValue?
        if let recipe = origin.recipe {
            guard let encoded = try? JSONValue(recipe) else { return nil }
            cameraRaw = encoded
        }
        self.bookmark = bookmark
        byteCount = origin.data.count
        digest = origin.digest
        type = origin.type
        self.width = width
        self.height = height
        self.develop = develop
        self.cameraRaw = cameraRaw
        seed = origin.seed
    }

    /// The file found again, with what it was developed with. Nil while the file is out of reach, when it is no longer
    /// the file that was developed, and when this build can't read the settings.
    func origin() -> RawOrigin? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count == byteCount,
              RawOrigin.digest(of: data) == digest,
              let settings = develop.decoded(over: RawDevelopSettings()), settings.isFinite else { return nil }
        var recipe: CameraRawSettings?
        if let cameraRaw {
            guard let read = cameraRaw.decoded(over: CameraRawSettings()) else { return nil }
            recipe = read.normalized
        }
        // A bookmark that resolved but has gone stale (the file was moved or renamed) is made again while the file is
        // in reach, for the next save.
        let current = stale ? RawOrigin.bookmark(of: url) ?? bookmark : bookmark
        return RawOrigin(data: data, type: type, settings: settings, recipe: recipe, seed: seed, bookmark: current, digest: digest)
    }
}

/// A layer record's `raw` member, kept whole. `link` is what this build reads of it, and nil when it can't: a recipe
/// that can't be read mustn't be what keeps a project from opening, and saving the project again writes back what
/// was there rather than losing it.
nonisolated struct RawLinkRecord: Codable, Equatable, Sendable {
    let saved: JSONValue

    init?(_ link: RawLink) {
        guard let saved = try? JSONValue(link) else { return nil }
        self.saved = saved
    }
    init(from decoder: Decoder) throws { saved = (try? JSONValue(from: decoder)) ?? .null }
    func encode(to encoder: Encoder) throws { try saved.encode(to: encoder) }

    var link: RawLink? {
        guard let data = try? JSONEncoder().encode(saved) else { return nil }
        return try? JSONDecoder().decode(RawLink.self, from: data)
    }
}

nonisolated extension RawOrigin {
    /// The SHA-256 of a file's first mebibyte, where a RAW file keeps the camera's own record of the shot. With the
    /// file's length it tells one file from another without reading 90 MB of it.
    static func digest(of data: Data) -> String {
        SHA256.hash(data: data.prefix(1 << 20)).map { String(format: "%02x", $0) }.joined()
    }

    /// A read-only bookmark of `url`, made while the file is in reach: by which a saved project finds it again.
    static func bookmark(of url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
