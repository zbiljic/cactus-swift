import Foundation

/// A top-level part of an `ImageDescription`.
public struct VisionSection: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let scene = Self(rawValue: "scene")
    public static let objects = Self(rawValue: "objects")
    public static let regions = Self(rawValue: "regions")
    public static let text = Self(rawValue: "text")
    public static let relations = Self(rawValue: "relations")
    public static let events = Self(rawValue: "events")
    public static let reasoning = Self(rawValue: "reasoning")
}

/// A per-item detail of objects and text lines. IDs, names and text strings are
/// always present.
public struct VisionField: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let bbox = Self(rawValue: "bbox")
    public static let score = Self(rawValue: "score")
    public static let point = Self(rawValue: "point")
    public static let mask = Self(rawValue: "mask")
    public static let position = Self(rawValue: "position")
    public static let description = Self(rawValue: "description")
}

/// How object masks are encoded.
public struct MaskFormat: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Outlines the largest part of the mask as one polygon.
    public static let largest = Self(rawValue: "largest")
    /// Outlines the whole mask as one polygon.
    public static let merged = Self(rawValue: "merged")
    /// Returns one polygon per part of the mask.
    public static let polygons = Self(rawValue: "polygons")
    /// Returns a run-length encoded pixel mask.
    public static let bitmap = Self(rawValue: "bitmap")
}

/// Controls a Mirage request. Nil values keep the engine defaults; an empty
/// `language`, `keywords` or `extra` adds nothing. The
/// engine validates names and ranges and reports invalid options as
/// `CactusError.nativeFailure`.
public struct DescribeOptions: Sendable, Equatable {
    /// The sections to return; nil returns all.
    public var sections: [VisionSection]?
    /// The per-item details; nil returns all but `point`, and an empty array
    /// returns only IDs, names and text strings.
    public var fields: [VisionField]?
    /// The object score threshold in (0, 1] ("conf").
    public var confidence: Double?
    /// The text line score threshold in (0, 1] ("text_conf").
    public var textConfidence: Double?
    public var maxObjects: Int?
    public var maxTextLines: Int?
    /// Bounds the generated description.
    public var maxTokens: Int?
    public var maskFormat: MaskFormat?
    /// Turns the engine's suppression of overlapping detections on or off.
    public var nms: Bool?
    /// The language of names and descriptions: empty for English, or de, fr, es,
    /// it, nl or pl. The engine rejects languages it does not support.
    public var language: String
    /// Words and phrases to favor.
    public var keywords: [String]
    /// Other cactus_describe options, such as keyword_bias, mask_threshold or
    /// mask_tolerance. It cannot repeat an option that has a property above, or
    /// form, language or keywords.
    public var extra: [String: JSONValue]

    public init(
        sections: [VisionSection]? = nil,
        fields: [VisionField]? = nil,
        confidence: Double? = nil,
        textConfidence: Double? = nil,
        maxObjects: Int? = nil,
        maxTextLines: Int? = nil,
        maxTokens: Int? = nil,
        maskFormat: MaskFormat? = nil,
        nms: Bool? = nil,
        language: String = "",
        keywords: [String] = [],
        extra: [String: JSONValue] = [:]
    ) {
        self.sections = sections
        self.fields = fields
        self.confidence = confidence
        self.textConfidence = textConfidence
        self.maxObjects = maxObjects
        self.maxTextLines = maxTextLines
        self.maxTokens = maxTokens
        self.maskFormat = maskFormat
        self.nms = nms
        self.language = language
        self.keywords = keywords
        self.extra = extra
    }

    /// Options set through the properties above or `extract`, which `extra`
    /// cannot repeat. The engine ignores language and keywords inside the options;
    /// they are separate cactus_describe arguments.
    static let reservedKeys: Set<String> = [
        "sections", "fields", "conf", "text_conf", "max_objects", "max_text_lines", "max_tokens",
        "mask_format", "nms", "form", "language", "keywords",
    ]

    /// Encodes the options JSON, with the form fields in order.
    func request(form: [FormField]?) throws -> VisionRequest {
        var entries = try typedEntries()
        for (key, value) in extra {
            guard !Self.reservedKeys.contains(key) else {
                throw CactusError.invalidInput("set vision option \(key) with its DescribeOptions property or extract")
            }
            entries[key] = try Self.json(value)
        }
        if let form {
            let fields = try form.map { try Self.json($0.name) + ":" + Self.json($0.schema) }
            entries["form"] = "{" + fields.joined(separator: ",") + "}"
        }
        let members = try entries.sorted { $0.key < $1.key }.map { try Self.json($0.key) + ":" + $0.value }
        let options = "{" + members.joined(separator: ",") + "}"
        let keywords = keywords.joined(separator: "\n")
        try validateCString(options, name: "vision options")
        try validateCString(language, name: "vision language")
        try validateCString(keywords, name: "vision keywords")
        return VisionRequest(options: options, language: language, keywords: keywords)
    }

    /// The JSON of each option set through a property.
    private func typedEntries() throws -> [String: String] {
        for (key, threshold) in [("conf", confidence), ("text_conf", textConfidence)] {
            guard threshold.map({ $0 > 0 && $0 <= 1 }) != false else {
                throw CactusError.invalidInput("vision option \(key) must be in (0, 1]")
            }
        }
        for (key, limit) in [("max_objects", maxObjects), ("max_text_lines", maxTextLines), ("max_tokens", maxTokens)] {
            if let limit, !(1 ... Int(Int32.max)).contains(limit) {
                throw CactusError.invalidInput("invalid vision option \(key) \(limit)")
            }
        }
        let values: [String: (any Encodable)?] = [
            "sections": sections, "fields": fields, "conf": confidence, "text_conf": textConfidence,
            "max_objects": maxObjects, "max_text_lines": maxTextLines, "max_tokens": maxTokens,
            "mask_format": maskFormat, "nms": nms,
        ]
        return try values.compactMapValues { $0 }.mapValues { try Self.json($0) }
    }

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try String(decoding: encoder.encode(value), as: UTF8.self)
        } catch {
            throw CactusError.invalidInput("encode vision options: \(error)")
        }
    }
}

/// The encoded arguments of one cactus_describe call.
struct VisionRequest: Sendable, Equatable {
    let options: String
    let language: String
    /// Newline-joined keywords.
    let keywords: String

    /// Passes nil for an empty language or keyword list.
    func withCStrings<T>(
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> T
    ) -> T {
        options.withCString { options in
            language.withCString { language in
                keywords.withCString { keywords in
                    body(
                        options,
                        self.language.isEmpty ? nil : language,
                        self.keywords.isEmpty ? nil : keywords
                    )
                }
            }
        }
    }
}

/// One field of an `extract` form. The engine reads `schema`; `choice`,
/// `count` and `text` build it for the common kinds, and other engine field
/// schemas pass through verbatim.
public struct FormField: Sendable, Equatable {
    public var name: String
    public var schema: [String: JSONValue]

    public init(name: String, schema: [String: JSONValue]) {
        self.name = name
        self.schema = schema
    }

    /// A field whose value is one of `choices`, as {"enum": choices}.
    public static func choice(_ name: String, _ choices: [String]) -> Self {
        Self(name: name, schema: ["enum": .array(choices.map { .string($0) })])
    }

    /// A bounded integer field, as {"type": "integer", "minimum", "maximum"}.
    public static func count(_ name: String, _ range: ClosedRange<Int>) -> Self {
        Self(name: name, schema: [
            "type": .string("integer"),
            "minimum": .integer(Int64(range.lowerBound)),
            "maximum": .integer(Int64(range.upperBound)),
        ])
    }

    /// A free text field of at most `maxLength` characters, as {"type": "string", "maxLength"}.
    public static func text(_ name: String, maxLength: Int) -> Self {
        Self(name: name, schema: ["type": .string("string"), "maxLength": .integer(Int64(maxLength))])
    }

    static func validate(_ form: [Self]) throws {
        guard !form.isEmpty else { throw CactusError.invalidInput("form has no fields") }
        var seen: Set<String> = []
        for field in form {
            guard !field.name.isEmpty, seen.insert(field.name).inserted else {
                throw CactusError.invalidInput("form field name \"\(field.name)\" is empty or repeated")
            }
        }
    }
}

public struct MirageConfiguration: Sendable {
    /// A trusted custom vision archive; nil or empty fetches the pinned Mirage weights.
    public var weightsPath: String?
    public var libraryPath: String?
    public var cacheDirectory: URL?
    /// Bounds the JSON response.
    public var bufferSize: Int

    public init(
        weightsPath: String? = nil,
        libraryPath: String? = nil,
        cacheDirectory: URL? = nil,
        bufferSize: Int = Mirage.defaultBufferSize
    ) {
        self.weightsPath = weightsPath
        self.libraryPath = libraryPath
        self.cacheDirectory = cacheDirectory
        self.bufferSize = bufferSize
    }
}

/// Opt-in image understanding on the Cactus engine: `describe` returns the scene,
/// objects, text and relations in an image, and `extract` fills a form from it.
/// Vision shares one serialized process-wide runtime with the other models the
/// engine runs, such as Needle 3 text and Whistle speech.
public final class Mirage: Sendable {
    /// Holds descriptions with polygon or bitmap masks for many objects, as upstream does.
    public static let defaultBufferSize = 16 * 1024 * 1024

    let session: VisionSession
    let runtime: NativeRuntime

    /// Loads vision weights without downloading or loading text or speech weights.
    public convenience init(configuration: MirageConfiguration = MirageConfiguration()) async throws {
        try await self.init(configuration: configuration, runtime: nil)
    }

    init(configuration: MirageConfiguration, runtime: NativeRuntime?) async throws {
        try Task.checkCancellation()
        guard (2 ... Int(Int32.max)).contains(configuration.bufferSize) else {
            throw CactusError.invalidInput("invalid buffer size \(configuration.bufferSize)")
        }
        try validateCString(configuration.weightsPath ?? "", name: "vision weights path")
        let library = try await Engine.resolveLibrary(
            generation: 3, path: configuration.libraryPath, cacheDirectory: configuration.cacheDirectory
        )
        let weights: URL = if let path = configuration.weightsPath, !path.isEmpty {
            URL(fileURLWithPath: path).standardizedFileURL
        } else {
            try await Engine.fetchVisionWeights(cacheDirectory: configuration.cacheDirectory)
        }
        session = VisionSession(weightsPath: weights.path, bufferSize: configuration.bufferSize)
        self.runtime = runtime ?? NativeRuntime.shared(for: 3)
        try await self.runtime.initializeVision(session, library: library)
    }

    /// Describes the scene, objects, text and relations in an image. If the engine
    /// JSON does not fit `ImageDescription`, it throws
    /// `CactusError.undecodableDescription` with the JSON.
    public func describe(
        _ image: RGBImage, options: DescribeOptions = DescribeOptions()
    ) async throws -> ImageDescription {
        let data = try await run(image, options: options, form: nil)
        do {
            var description = try JSONDecoder().decode(ImageDescription.self, from: data)
            description.raw = data
            return description
        } catch {
            throw CactusError.undecodableDescription(raw: data, detail: "\(error)")
        }
    }

    /// Fills `form` from an image and returns the values by field name. Fields are
    /// filled in order, so a field can depend on earlier ones. `sections` and
    /// `fields` are passed to the engine but have no effect on forms.
    public func extract(
        _ image: RGBImage, form: [FormField], options: DescribeOptions = DescribeOptions()
    ) async throws -> [String: FormValue] {
        try FormField.validate(form)
        let data = try await run(image, options: options, form: form)
        struct Filled: Decodable {
            let form: [String: FormValue]?
        }
        let filled: Filled
        do {
            filled = try JSONDecoder().decode(Filled.self, from: data)
        } catch {
            throw CactusError.native("decode form: \(error)")
        }
        guard let values = filled.form else { throw CactusError.native("engine response has no form") }
        return values
    }

    /// Releases this Mirage's binding. Later calls throw `CactusError.closed`.
    /// Loaded vision weights stay in the engine for other Mirage values.
    public func close() async {
        await runtime.closeVision(session)
    }

    private func run(_ image: RGBImage, options: DescribeOptions, form: [FormField]?) async throws -> Data {
        try Task.checkCancellation()
        let request = try options.request(form: form)
        return try await runtime.describe(session, image: image, request: request)
    }
}

struct VisionSession: Sendable {
    let id = UUID()
    let weightsPath: String
    let bufferSize: Int

    /// Reads the vision archive, rejecting other kinds before they reach the engine.
    func archive() throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: weightsPath))
        } catch {
            throw CactusError.invalidInput("read vision weights: \(error.localizedDescription)")
        }
        guard WeightMetadata(data)?.kind == .vision else {
            throw CactusError.invalidInput("weights are not a recognized vision model")
        }
        return data
    }
}
