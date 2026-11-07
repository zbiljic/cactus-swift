import Foundation

/// A Mirage response. Sections not requested are nil.
public struct ImageDescription: Codable, Sendable, Equatable {
    /// Attributes such as background, lighting and style.
    public var scene: [String: String]?
    public var objects: [VisionObject]?
    public var regions: [JSONValue]?
    public var text: [TextLine]?
    public var relations: [Relation]?
    public var events: [JSONValue]?
    /// The model's short rationale.
    public var reasoning: String?
    /// The engine's JSON, including any part these types do not model.
    public var raw = Data()

    public init(
        scene: [String: String]? = nil,
        objects: [VisionObject]? = nil,
        regions: [JSONValue]? = nil,
        text: [TextLine]? = nil,
        relations: [Relation]? = nil,
        events: [JSONValue]? = nil,
        reasoning: String? = nil,
        raw: Data = Data()
    ) {
        self.scene = scene
        self.objects = objects
        self.regions = regions
        self.text = text
        self.relations = relations
        self.events = events
        self.reasoning = reasoning
        self.raw = raw
    }

    enum CodingKeys: String, CodingKey {
        case scene, objects, regions, text, relations, events, reasoning
    }
}

/// A detected object. Coordinates are in a 0 to 1000 space over the image width
/// and height; multiply x by width/1000 and y by height/1000 for pixels. Details
/// not selected by `DescribeOptions.fields` are nil.
public struct VisionObject: Codable, Sendable, Equatable {
    public var id: Int
    public var name: String
    /// [x0, y0, x1, y1].
    public var bbox: [Double]?
    public var score: Double?
    /// An [x, y] point on the object.
    public var point: [Double]?
    public var mask: Mask?
    /// A coarse placement, such as "left" or "top".
    public var position: String?
    /// Attributes such as color and shape (the engine's "description").
    public var attributes: [String: String]?

    public init(
        id: Int,
        name: String,
        bbox: [Double]? = nil,
        score: Double? = nil,
        point: [Double]? = nil,
        mask: Mask? = nil,
        position: String? = nil,
        attributes: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.bbox = bbox
        self.score = score
        self.point = point
        self.mask = mask
        self.position = position
        self.attributes = attributes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, bbox, score, point, mask, position
        case attributes = "description"
    }
}

/// A line of recognized text, with details as in `VisionObject`.
public struct TextLine: Codable, Sendable, Equatable {
    public var text: String
    public var bbox: [Double]?
    public var score: Double?
    public var point: [Double]?

    public init(text: String, bbox: [Double]? = nil, score: Double? = nil, point: [Double]? = nil) {
        self.text = text
        self.bbox = bbox
        self.score = score
        self.point = point
    }

    enum CodingKeys: String, CodingKey {
        case text = "string"
        case bbox, score, point
    }
}

/// Links two objects by ID, as in (1, "next_to", 2).
public struct Relation: Codable, Sendable, Equatable {
    public var subject: Int
    public var predicate: String
    public var object: Int

    public init(subject: Int, predicate: String, object: Int) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

/// An object mask.
public enum Mask: Codable, Sendable, Equatable {
    /// Flattened x0, y0, x1, y1, ... outlines in the 0 to 1000 space; one for
    /// `MaskFormat.largest` and `.merged`, one per part for `.polygons`.
    case polygons([[Double]])
    /// `MaskFormat.bitmap`: an uncompressed COCO run-length encoding over the
    /// image's pixels, alternating runs of background and mask pixels in
    /// column-major order, starting with background.
    case runLength(height: Int, width: Int, counts: [Int])

    private enum RunLengthKeys: String, CodingKey {
        case size, counts
    }

    /// Accepts a flat polygon, a list of polygons or a run-length encoded bitmap.
    /// A bitmap without a size or counts decodes as empty, which `bitmap()`
    /// rejects.
    public init(from decoder: any Decoder) throws {
        if let bitmap = try? decoder.container(keyedBy: RunLengthKeys.self) {
            let size = try bitmap.decodeIfPresent([Int].self, forKey: .size) ?? [0, 0]
            guard size.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .size, in: bitmap, debugDescription: "mask size must be [height, width]"
                )
            }
            let counts = try bitmap.decodeIfPresent([Int].self, forKey: .counts) ?? []
            self = .runLength(height: size[0], width: size[1], counts: counts)
            return
        }
        let container = try decoder.singleValueContainer()
        if let polygon = try? container.decode([Double].self) {
            self = .polygons(polygon.isEmpty ? [] : [polygon])
        } else {
            self = try .polygons(container.decode([[Double]].self))
        }
    }

    /// Writes a bitmap as {"size": [height, width], "counts"} and polygons as a
    /// list of flattened polygons.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .polygons(polygons):
            var container = encoder.singleValueContainer()
            try container.encode(polygons)
        case let .runLength(height, width, counts):
            var container = encoder.container(keyedBy: RunLengthKeys.self)
            try container.encode([height, width], forKey: .size)
            try container.encode(counts, forKey: .counts)
        }
    }

    /// Decodes a run-length mask to `height * width` row-major bytes, 0xff for
    /// mask pixels. Returns nil for polygons or an inconsistent encoding.
    public func bitmap() -> [UInt8]? {
        guard
            case let .runLength(height, width, counts) = self, height > 0, width > 0,
            height <= Int(Int32.max) / width else { return nil }
        let total = height * width
        var pixels = [UInt8](repeating: 0, count: total)
        var position = 0
        for (index, count) in counts.enumerated() {
            guard count >= 0, count <= total - position else { return nil }
            if index % 2 == 1 {
                for pixel in position ..< position + count {
                    pixels[(pixel % height) * width + pixel / height] = 0xFF
                }
            }
            position += count
        }
        return position == total ? pixels : nil
    }
}

/// A filled form field.
public struct FormValue: Codable, Sendable, Equatable {
    /// A string for choice and text fields and a number for count fields. A
    /// choice the model declines is `.null`; a declined text field is "-".
    public var value: JSONValue
    /// The confidence of a text value.
    public var probability: Double?
    /// Each choice or count and its probability; "-" is the probability of no value.
    public var probabilities: [String: Double]?

    public init(value: JSONValue, probability: Double? = nil, probabilities: [String: Double]? = nil) {
        self.value = value
        self.probability = probability
        self.probabilities = probabilities
    }

    enum CodingKeys: String, CodingKey {
        case value, probability, probabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        probability = try container.decodeIfPresent(Double.self, forKey: .probability)
        probabilities = try container.decodeIfPresent([String: Double].self, forKey: .probabilities)
    }
}
