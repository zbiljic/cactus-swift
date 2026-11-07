@testable import Cactus
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A fake Cactus engine for vision with text, speech and stream stubs. State is
/// shared by @Sendable native callbacks and assertions, always under the lock.
final class VisionProbe: @unchecked Sendable {
    struct Call {
        let image: RGBImage
        let request: VisionRequest
        let capacity: Int
    }

    struct State {
        var loads: [Data] = []
        var loadCode: Int32 = 0
        var models: Int32 = 7
        var output = #"{"objects":[],"text":[]}"#
        var code: Int32 = 0
        var lastError = ""
        var calls: [Call] = []
    }

    let text = FakeNative(Array(repeating: #"{"type":"respond"}"#, count: 8))
    private let lock = NSLock()
    private var state = State()

    var snapshot: State {
        lock.withLock { state }
    }

    func update(_ body: (inout State) -> Void) {
        lock.withLock { body(&state) }
    }

    var api: NativeAPI {
        let base = text.api
        var api = NativeAPI(
            initialize: base.initialize,
            complete: base.complete,
            reset: base.reset
        ) { bytes, size in
            self.lock.withLock {
                self.state.loads.append(Data(bytes: bytes, count: Int(size)))
                return self.state.loadCode
            }
        }
        api.lastError = { self.snapshot.lastError }
        var cactus = CactusFunctions.unused
        cactus.models = { self.snapshot.models }
        cactus.describe = { image, request, output in
            self.lock.withLock {
                self.state.calls.append(Call(image: image, request: request, capacity: output.count))
                Self.write(self.state.output, to: output)
                return self.state.code
            }
        }
        cactus.transcribe = { _, _, output in
            Self.write(#"{"text":"","language":"","ttft_ms":1,"decode_tps":1}"#, to: output)
            return 0
        }
        cactus.streamProcess = { _, _, output in
            Self.write(#"{"text":"","pending":"","language":"en","received":1,"pass_ms":1}"#, to: output)
            return 0
        }
        cactus.streamStop = { output in
            Self.write(#"{"text":"","received":1}"#, to: output)
            return 0
        }
        api.cactus = cactus
        return api
    }

    private static func write(_ json: String, to output: UnsafeMutableBufferPointer<CChar>) {
        for (index, byte) in json.utf8.prefix(output.count).enumerated() {
            output[index] = CChar(bitPattern: byte)
        }
    }
}

/// A directory with vision, speech and text archives.
private struct VisionFixture {
    let directory: URL
    let probe = VisionProbe()
    let runtime: NativeRuntime

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in [
            ("vision.cact", testWeights(vision: true)),
            ("other.cact", testWeights(vision: true)),
            ("speech.cact", testWeights(speech: true)),
            ("text.cact", testWeights(heads: [0x4000])),
        ] {
            try data.write(to: directory.appendingPathComponent(name))
        }
        runtime = NativeRuntime(api: probe.api)
    }

    func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    func mirage(_ name: String = "vision.cact", bufferSize: Int = 4096) async throws -> Mirage {
        try await Mirage(
            configuration: MirageConfiguration(
                weightsPath: path(name), libraryPath: "/test/libneedle.dylib", bufferSize: bufferSize
            ),
            runtime: runtime
        )
    }

    func whistle(_ name: String = "speech.cact") async throws -> Whistle {
        try await Whistle(
            configuration: WhistleConfiguration(weightsPath: path(name), libraryPath: "/test/libneedle.dylib"),
            runtime: runtime
        )
    }

    func agent(_ name: String = "text.cact") async throws -> Agent {
        try await Agent(
            configuration: Configuration(weightsPath: path(name), libraryPath: "/test/libneedle.dylib"),
            runtime: runtime
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private let pixel = try! RGBImage(width: 1, height: 1, pixels: [0, 0, 0]) // swiftlint:disable:this force_try

@Test
func recognizesVisionManifest() {
    let valid = testWeights(vision: true)
    #expect(WeightMetadata(valid)?.kind == .vision)
    let record = 308 + 67 * 44
    let manifest = Int(valid[record + 20]) | Int(valid[record + 21]) << 8
    // Truncation is caught up to the end of the manifest; the engine validates later tensors.
    for size in 0 ..< manifest + 36 * 4 {
        #expect(WeightMetadata(Data(valid.prefix(size)))?.kind != .vision)
    }
    for other in [testWeights(speech: true), testWeights(heads: [0x4000]), testWeights()] {
        #expect(WeightMetadata(other)?.kind != .vision)
    }
    let mutations: [(inout Data) -> Void] = [
        { $0.put(Float(4722).bitPattern, at: manifest) }, // Unknown manifest.
        { // Another length, in an otherwise valid record.
            $0.put(UInt32(35), at: record + 4)
            $0.put(UInt64(35 * 4), at: record + 28)
        },
        { $0[record] = 1 }, // FP16 manifest.
        { $0.put(UInt32(68), at: 4) }, // The manifest is the last tensor.
    ]
    for mutate in mutations {
        var invalid = valid
        mutate(&invalid)
        #expect(WeightMetadata(invalid)?.kind == nil)
    }
}

@Test // swiftlint:disable:next function_body_length
func mirageDescribesWithoutChangingTextOrSpeech() async throws {
    let fixture = try VisionFixture()
    defer { fixture.remove() }
    let agent = try await fixture.agent()
    let speech = try await fixture.whistle()
    let mirage = try await fixture.mirage()
    #expect(fixture.probe.snapshot.loads == [
        testWeights(heads: [0x4000]),
        testWeights(speech: true),
        testWeights(vision: true),
    ])
    fixture.probe.update {
        $0.output = #"""
        {"scene":{"background":"white"},"objects":[{"id":1,"name":"red square","bbox":[1,2,3,4],"score":0.8,
         "point":[2,3],"mask":{"size":[2,3],"counts":[1,2,3]},"position":"left","description":{"color":"red"}}],
         "text":[{"string":"OPEN","bbox":[5,6,7,8],"score":0.4}],"relations":[{"subject":1,"predicate":"next_to",
         "object":2}],"regions":[{"kind":"sky"}],"events":[],"reasoning":"lang: pl","future":1}
        """#
        $0.code = 42 // A token count, not the length of the JSON.
    }
    let image = try RGBImage(width: 3, height: 2, pixels: Array(1 ... 18))
    let description = try await mirage.describe(image, options: DescribeOptions(
        sections: [.objects, .text],
        fields: [],
        confidence: 0.5,
        maxObjects: 3,
        maskFormat: .bitmap,
        nms: false,
        language: "pl",
        keywords: ["Łódź", "café"],
        extra: ["mask_tolerance": .integer(2)]
    ))
    let call = try #require(fixture.probe.snapshot.calls.last)
    #expect(call.image == image && call.capacity == 4096)
    #expect(call.request == VisionRequest(
        options: #"{"conf":0.5,"fields":[],"mask_format":"bitmap","mask_tolerance":2,"max_objects":3,"#
            + #""nms":false,"sections":["objects","text"]}"#,
        language: "pl",
        keywords: "Łódź\ncafé"
    ))
    let object = VisionObject(
        id: 1,
        name: "red square",
        bbox: [1, 2, 3, 4],
        score: 0.8,
        point: [2, 3],
        mask: .runLength(height: 2, width: 3, counts: [1, 2, 3]),
        position: "left",
        attributes: ["color": "red"]
    )
    #expect(description.scene == ["background": "white"] && description.objects == [object])
    #expect(description.text == [TextLine(text: "OPEN", bbox: [5, 6, 7, 8], score: 0.4)])
    #expect(description.relations == [Relation(subject: 1, predicate: "next_to", object: 2)])
    #expect(description.regions == [.object(["kind": .string("sky")])] && description.events?.isEmpty == true)
    #expect(description.reasoning == "lang: pl")
    #expect(String(decoding: description.raw, as: UTF8.self).contains(#""future":1"#))
    // Text and speech stay loaded: neither reloads nor reinitializes.
    _ = try await agent.complete("hello")
    _ = try await speech.transcribe([])
    #expect(fixture.probe.text.snapshot.systems.count == 1 && fixture.probe.snapshot.loads.count == 3)
    // A second vision model switches independently; a repeated call does not reload.
    let second = try await fixture.mirage("other.cact")
    for vision in [second, mirage, mirage] {
        _ = try await vision.describe(pixel)
    }
    #expect(fixture.probe.snapshot.loads.count == 5)
    _ = try await agent.complete("hello")
    #expect(fixture.probe.text.snapshot.systems.count == 1)
}

@Test
func mirageDuringLiveTranscriptionKeepsTheStream() async throws {
    let fixture = try VisionFixture()
    defer { fixture.remove() }
    let speech = try await fixture.whistle()
    let mirage = try await fixture.mirage()
    let live = try speech.stream()
    _ = try await live.process([0])
    _ = try await mirage.describe(pixel)
    // Loading other vision weights does not touch the stream either.
    _ = try await fixture.mirage("other.cact").describe(pixel)
    _ = try await live.process([0])
    _ = try await live.stop()
    #expect(fixture.probe.snapshot.loads.count == 3)
}

@Test
func mirageRejectsWrongKindWithoutNativeLoad() async throws {
    let fixture = try VisionFixture()
    defer { fixture.remove() }
    let agent = try await fixture.agent()
    _ = try await fixture.whistle()
    _ = try await fixture.mirage()
    let loads = fixture.probe.snapshot.loads.count
    for name in ["speech.cact", "text.cact"] {
        await #expect { try await fixture.mirage(name) } throws: {
            $0.localizedDescription == "cactus: weights are not a recognized vision model"
        }
    }
    await #expect { try await fixture.agent("vision.cact") } throws: {
        $0.localizedDescription == "cactus: weights are not a recognized text model"
    }
    await #expect { try await fixture.whistle("vision.cact") } throws: {
        $0.localizedDescription == "cactus: weights are not a recognized speech model"
    }
    #expect(fixture.probe.snapshot.loads.count == loads)
    _ = try await agent.complete("hello")
    #expect(fixture.probe.text.snapshot.systems.count == 1)
}

@Test
func mirageLoadFailures() async throws {
    let fixture = try VisionFixture()
    defer { fixture.remove() }
    let mirage = try await fixture.mirage()
    // A load the engine accepts without reporting a vision model fails closed.
    fixture.probe.update { $0.models = 3 }
    await #expect { try await fixture.mirage("other.cact") } throws: {
        $0.localizedDescription == "cactus: engine did not load the vision model"
    }
    fixture.probe.update {
        $0.models = 7
        $0.loadCode = -3
        $0.lastError = "load detail"
    }
    await #expect { try await fixture.mirage("other.cact") } throws: { error in
        guard case let .nativeFailure(operation, code, detail) = error as? CactusError else { return false }
        return operation == "load vision weights" && code == -3 && detail == "load detail"
    }
    // A failed load forgets the loaded vision weights, so the next call reloads them.
    fixture.probe.update { $0.loadCode = 0 }
    let loads = fixture.probe.snapshot.loads.count
    _ = try await mirage.describe(pixel)
    #expect(fixture.probe.snapshot.loads.count == loads + 1)
    #expect(fixture.probe.snapshot.loads.last == testWeights(vision: true))
    // A description that does not fit the types still returns the JSON.
    fixture.probe.update { $0.output = #"{"scene":{"count":3}}"# }
    await #expect { try await mirage.describe(pixel) } throws: { error in
        guard case let .undecodableDescription(raw, _) = error as? CactusError else { return false }
        return raw == Data(#"{"scene":{"count":3}}"#.utf8)
            && error.localizedDescription.hasPrefix("cactus: decode description: ")
    }
}

@Test
func mirageInputValidationPrecedesNativeCalls() async throws {
    let fixture = try VisionFixture()
    defer { fixture.remove() }
    let mirage = try await fixture.mirage()
    for (width, height, count) in [(0, 4, 0), (1, 2, 5), (1, 1, 4), (-1, -1, 0), (1 << 16, 1 << 16, 0)] {
        #expect(throws: CactusError.self) {
            try RGBImage(width: width, height: height, pixels: [UInt8](repeating: 0, count: count))
        }
    }
    let invalidOptions = [
        DescribeOptions(confidence: .nan),
        DescribeOptions(confidence: 0),
        DescribeOptions(textConfidence: 1.5),
        DescribeOptions(maxObjects: 0),
        DescribeOptions(maxTokens: -1),
        DescribeOptions(maxTextLines: Int(Int32.max) + 1),
        DescribeOptions(extra: ["keyword_bias": .number(.nan)]),
        DescribeOptions(language: "en\0"),
        DescribeOptions(keywords: ["a\0"]),
    ] + DescribeOptions.reservedKeys.map { DescribeOptions(extra: [$0: .null]) }
    for options in invalidOptions {
        await #expect(throws: CactusError.self) { try await mirage.describe(pixel, options: options) }
    }
    for form: [FormField] in [
        [],
        [FormField(name: "", schema: ["enum": .array([.string("a")])])],
        [.choice("a", ["x"]), .choice("a", ["y"])],
        [FormField(name: "a", schema: ["enum": .number(.nan)])],
    ] {
        await #expect(throws: CactusError.self) { try await mirage.extract(pixel, form: form) }
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await mirage.describe(pixel)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    for size in [0, 1, Int(Int32.max) + 1] {
        await #expect(throws: CactusError.self) { try await fixture.mirage(bufferSize: size) }
    }
    #expect(fixture.probe.snapshot.calls.isEmpty && fixture.probe.snapshot.loads.count == 1)
}

@Test
func mirageReportsEngineAndDecodeErrors() async throws {
    let fixture = try VisionFixture()
    defer { fixture.remove() }
    let mirage = try await fixture.mirage()
    for (output, message) in [
        ("invalid JSON", "cactus: decode description"),
        (String(repeating: "x", count: 4096), "cactus: engine response exceeds buffer"),
    ] {
        fixture.probe.update { $0.output = output }
        await #expect { try await mirage.describe(pixel) } throws: { $0.localizedDescription.hasPrefix(message) }
    }
    for (output, message) in [
        (#"{"objects":[]}"#, "cactus: engine response has no form"),
        (#"{"form":{"a":{"probabilities":{"x":null}}}}"#, "cactus: decode form: "),
    ] {
        fixture.probe.update { $0.output = output }
        await #expect { try await mirage.extract(pixel, form: [.choice("a", ["x"])]) } throws: {
            $0 is CactusError && $0.localizedDescription.hasPrefix(message)
        }
    }
    await #expect { try await fixture.mirage("missing.cact") } throws: {
        $0.localizedDescription.hasPrefix("cactus: read vision weights: ")
    }
    fixture.probe.update {
        $0.output = #"{"stale":true}"#
        $0.code = -1
        $0.lastError = "invalid options: mask_format must be largest, merged, polygons or bitmap"
    }
    await #expect {
        try await mirage.describe(pixel, options: DescribeOptions(maskFormat: MaskFormat(rawValue: "outline")))
    } throws: { error in
        guard case let .nativeFailure(operation, _, detail) = error as? CactusError else { return false }
        return operation == "describe" && detail.contains("mask_format")
    }
}

@Test
func extractKeepsFieldOrder() async throws {
    let fixture = try VisionFixture()
    defer { fixture.remove() }
    let mirage = try await fixture.mirage()
    fixture.probe.update {
        $0.output = #"""
        {"form":{"color":{"value":"red","probabilities":{"red":0.9,"blue":0.05,"-":0.05}},
         "legs":{"value":4,"probabilities":{"4":1}},"label":{"value":"OPEN","probability":0.6},
         "z":{"value":null,"probability":0.2}}}
        """#
    }
    let form: [FormField] = [
        .choice("color", ["red", "blue"]),
        .count("legs", 0 ... 4),
        .text("label", maxLength: 12),
        FormField(name: "z", schema: ["type": .string("string"), "x-source": .string("color")]),
    ]
    let values = try await mirage.extract(pixel, form: form, options: DescribeOptions(maxTokens: 64))
    #expect(fixture.probe.snapshot.calls.last?.request.options == #"{"form":{"color":{"enum":["red","blue"]},"#
        + #""legs":{"maximum":4,"minimum":0,"type":"integer"},"label":{"maxLength":12,"type":"string"},"#
        + #""z":{"type":"string","x-source":"color"}},"max_tokens":64}"#)
    #expect(values == [
        "color": FormValue(value: .string("red"), probabilities: ["red": 0.9, "blue": 0.05, "-": 0.05]),
        "legs": FormValue(value: .integer(4), probabilities: ["4": 1]),
        "label": FormValue(value: .string("OPEN"), probability: 0.6),
        "z": FormValue(value: .null, probability: 0.2),
    ])
}

@Test
func mirageClose() async throws {
    let fixture = try VisionFixture()
    defer { fixture.remove() }
    let mirage = try await fixture.mirage()
    await mirage.close()
    await mirage.close()
    await #expect { try await mirage.describe(pixel) } throws: {
        $0.localizedDescription == CactusError.closed.localizedDescription
    }
    await #expect { try await mirage.extract(pixel, form: [.choice("a", ["x"])]) } throws: {
        $0.localizedDescription == CactusError.closed.localizedDescription
    }
    #expect(fixture.probe.snapshot.calls.isEmpty && fixture.probe.snapshot.loads.count == 1)
}

@Test
func describeCABIArguments() throws {
    let describe: NativeAPI.Describe = { rgb, width, height, options, language, keywords, output, capacity in
        guard
            let rgb, rgb[0] == 9, width == 1, height == 1, let options,
            String(cString: options) == #"{"sections":["scene"]}"#, capacity == 32 else { return -1 }
        let language = language.map { String(cString: $0) } ?? "nil"
        let keywords = keywords.map { String(cString: $0) } ?? "nil"
        let reply = "\(language)|\(keywords)"
        for (index, byte) in reply.utf8.enumerated() {
            output?[index] = CChar(bitPattern: byte)
        }
        output?[reply.utf8.count] = 0
        // The engine reports the pixel address so the test can check that it was not copied.
        return Int32(truncatingIfNeeded: Int(bitPattern: UnsafeRawPointer(rgb)))
    }
    var symbols = nativeSymbols(generation: 3)
    symbols["cactus_describe"] = address(describe)
    let api = try #require(NativeAPI.bind(generation: 3) { symbols[$0] }.cactus)
    let image = try RGBImage(width: 1, height: 1, pixels: [9, 8, 7])
    let address = image.pixels.withUnsafeBufferPointer { Int32(truncatingIfNeeded: Int(bitPattern: $0.baseAddress)) }
    for (options, reply) in [
        (DescribeOptions(sections: [.scene], language: "en", keywords: ["Paris", "Ada"]), "en|Paris\nAda"),
        (DescribeOptions(sections: [.scene]), "nil|nil"),
    ] {
        var buffer = [CChar](repeating: 0, count: 32)
        let request = try options.request(form: nil)
        #expect(buffer.withUnsafeMutableBufferPointer { api.describe(image, request, $0) } == address)
        #expect(String(cString: buffer) == reply)
    }
}
