@testable import Cactus
import CoreGraphics
import Foundation
import Testing

/// A white RGB canvas. A 5x7 bitmap font draws the characters of `testSceneText`.
private struct Canvas {
    static let glyphs: [Character: [String]] = [
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "N": ["#...#", "##..#", "#.#.#", "#.#.#", "#..##", "#...#", "#...#"],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    ]

    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0xFF, count: width * height * 3)
    }

    mutating func fill(_ rect: CGRect, _ color: [UInt8], inside: (Int, Int) -> Bool = { _, _ in true }) {
        for row in Int(rect.minY) ..< Int(rect.maxY) {
            for column in Int(rect.minX) ..< Int(rect.maxX) where inside(column, row) {
                pixels.replaceSubrange((row * width + column) * 3 ..< (row * width + column + 1) * 3, with: color)
            }
        }
    }

    mutating func draw(_ text: String, at origin: CGPoint, scale: Int) {
        for (index, character) in text.enumerated() {
            for (row, line) in (Self.glyphs[character] ?? []).enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "#" {
                    let left = Int(origin.x) + (index * 6 + column) * scale
                    let top = Int(origin.y) + row * scale
                    fill(CGRect(x: left, y: top, width: scale, height: scale), [0, 0, 0])
                }
            }
        }
    }

    func image() throws -> RGBImage {
        try RGBImage(width: width, height: height, pixels: pixels)
    }
}

// Drawn shapes of the test scene, in pixels.
private let sceneSize = CGSize(width: 512, height: 384)
private let redSquare = CGRect(x: 48, y: 160, width: 160, height: 160)
private let blueCircle = CGRect(x: 304, y: 160, width: 160, height: 160)
private let red: [UInt8] = [0xDC, 0x14, 0x14]

/// Text above a red square and a blue circle on white.
private func testScene() -> Canvas {
    var canvas = Canvas(width: Int(sceneSize.width), height: Int(sceneSize.height))
    canvas.draw("OPEN 24", at: CGPoint(x: 48, y: 40), scale: 8)
    canvas.fill(redSquare, red)
    canvas.fill(blueCircle, [0x14, 0x28, 0xDC]) { column, row in
        let (dx, dy) = (column - Int(blueCircle.midX), row - Int(blueCircle.midY))
        return dx * dx + dy * dy < 80 * 80
    }
    return canvas
}

/// Converts a 0-1000 box to pixels.
private func pixelBox(_ box: [Double]) -> CGRect {
    let x0 = (box[0] * sceneSize.width / 1000).rounded()
    let y0 = (box[1] * sceneSize.height / 1000).rounded()
    let x1 = (box[2] * sceneSize.width / 1000).rounded()
    let y1 = (box[3] * sceneSize.height / 1000).rounded()
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

private func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> Double {
    let intersection = first.intersection(second)
    let area = { (rect: CGRect) in rect.isNull ? 0 : rect.width * rect.height }
    return area(intersection) / (area(first) + area(second) - area(intersection))
}

private func object(_ objects: [VisionObject]?, named word: String) -> VisionObject? {
    objects?.first { $0.name.contains(word) }
}

extension NativeRuntime {
    /// The engine's bitmask of loaded model kinds; nil without a Cactus engine.
    func loadedModels() -> Int32? {
        api?.cactus?.models()
    }
}

extension NativeIntegrationTests {
    @Test
    func nativeMirage() async throws {
        let vision = try await Mirage()
        let visionBlob = try Data(contentsOf: URL(fileURLWithPath: vision.session.weightsPath))
        #expect(WeightMetadata(visionBlob)?.kind == .vision)
        #expect(try #require(await vision.runtime.loadedModels()) & CactusFunctions.visionModel != 0)

        // Decode the scene from PNG, as a caller reading a file would.
        let scene = testScene()
        let png = try encodeImage(
            makeImage(scene.pixels, scene.width, scene.height, channels: 3, alpha: .none),
            as: .png
        )
        let image = try RGBImage(data: png)
        let description = try await vision.describe(image)
        print("description:", String(decoding: description.raw, as: UTF8.self))
        #expect(description.scene?["background"] == "white" && description.reasoning?.isEmpty == false)
        let square = try #require(object(description.objects, named: "square"))
        let circle = try #require(object(description.objects, named: "circle"))
        #expect(square.attributes?["color"] == "red" && circle.attributes?["color"] == "blue")
        for (detected, drawn) in [(square, redSquare), (circle, blueCircle)] {
            let box = try #require(detected.bbox)
            #expect(box.count == 4 && detected.score ?? 0 > 0 && detected.point == nil && detected.position != nil)
            guard case let .polygons(polygons) = detected.mask else {
                Issue.record("\(detected.name) mask = \(String(describing: detected.mask))")
                continue
            }
            #expect(polygons.count == 1)
            #expect(intersectionOverUnion(pixelBox(box), drawn) >= 0.8, "\(detected.name) box \(pixelBox(box))")
        }
        #expect(description.text?.contains { $0.text.uppercased().contains("OPEN") && $0.bbox?.count == 4 } == true)

        // Packed RGB reaches the engine unchanged and gives the same answer.
        #expect(try await vision.describe(scene.image()).raw == description.raw)

        try await nativeMirageBitmapMask(vision, image: image)
        try await nativeMirageForm(vision)
        try await nativeMirageDiagnostics(vision, image: image)
        try await nativeMirageSharesTheEngine(vision, image: image, description: description, blob: visionBlob)
    }

    /// A bitmap mask decodes onto the drawn square.
    private func nativeMirageBitmapMask(_ vision: Mirage, image: RGBImage) async throws {
        let masks = try await vision.describe(image, options: DescribeOptions(
            sections: [.objects], fields: [.mask, .point], maskFormat: .bitmap
        ))
        #expect(masks.scene == nil && masks.text == nil)
        #expect(masks.objects?.first?.bbox == nil && masks.objects?.first?.point?.count == 2)
        let maskedSquare = try #require(object(masks.objects, named: "square"))
        let point = try #require(maskedSquare.point)
        #expect(redSquare.contains(CGPoint(x: point[0] * 512 / 1000, y: point[1] * 384 / 1000)))
        guard case let .runLength(height, width, _) = maskedSquare.mask, let bitmap = maskedSquare.mask?.bitmap() else {
            Issue.record("bitmap mask = \(String(describing: maskedSquare.mask))")
            return
        }
        #expect(width == 512 && height == 384)
        var (inside, outside) = (0, 0)
        for (index, value) in bitmap.enumerated() where value != 0 {
            if redSquare.contains(CGPoint(x: index % width, y: index / width)) {
                inside += 1
            } else {
                outside += 1
            }
        }
        let area = Int(redSquare.width * redSquare.height)
        #expect(Double(inside) >= 0.9 * Double(area) && Double(outside) <= 0.1 * Double(area), "\(inside) \(outside)")
    }

    /// A form is filled in order with constrained values.
    private func nativeMirageForm(_ vision: Mirage) async throws {
        var lone = Canvas(width: 256, height: 256)
        lone.fill(CGRect(x: 64, y: 64, width: 128, height: 128), red)
        let values = try await vision.extract(lone.image(), form: [
            .choice("color", ["red", "green", "blue"]),
            .count("count", 0 ... 5),
            .choice("shape", ["circle", "square", "triangle"]),
        ])
        print("form:", values)
        #expect(values.count == 3 && values["color"]?.value == .string("red") && values["count"]?.value == .integer(1))
        // The model may decline a choice ("-"), which leaves the value null.
        let shape = try #require(values["shape"])
        #expect([.null, .string("circle"), .string("square"), .string("triangle")].contains(shape.value))
        #expect(shape.probabilities?["-"] ?? 0 > 0)
        for (name, value) in values {
            let total = value.probabilities?.values.reduce(0, +) ?? 0
            #expect(abs(total - 1) <= 0.01, "\(name) probabilities sum to \(total)")
        }
    }

    /// Engine diagnostics surface as native failures, and the language changes names.
    private func nativeMirageDiagnostics(_ vision: Mirage, image: RGBImage) async throws {
        for (options, detail) in [
            (DescribeOptions(maskFormat: MaskFormat(rawValue: "outline")), "mask_format"),
            (DescribeOptions(language: "xx"), "unsupported language"),
        ] {
            await #expect { try await vision.describe(image, options: options) } throws: { error in
                guard case let .nativeFailure(_, _, message) = error as? CactusError else { return false }
                return message.contains(detail)
            }
        }
        let small = try await Mirage(configuration: MirageConfiguration(bufferSize: 16))
        await #expect { try await small.describe(image) } throws: { error in
            guard case let .nativeFailure(_, _, message) = error as? CactusError else { return false }
            return message.contains("too small")
        }
        let german = try await vision.describe(
            image, options: DescribeOptions(sections: [.objects], fields: [], language: "de")
        )
        #expect(german.objects?.isEmpty == false && object(german.objects, named: "square") == nil)
    }

    /// Text, speech and vision share the engine: models=7. Loading and running
    /// vision preserves a pending text tool call and an open stream.
    private func nativeMirageSharesTheEngine(
        _ vision: Mirage, image: RGBImage, description: ImageDescription, blob: Data
    ) async throws {
        let runtime = vision.runtime
        let agent = try await Agent(configuration: Configuration(tools: [Tool(schema: weatherSchema)]))
        let speech = try await Whistle()
        #expect(await runtime.loadedModels() == 7)
        let visionPath = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cact")
        try blob.write(to: visionPath)
        defer { try? FileManager.default.removeItem(at: visionPath) }
        var baseline: Response?
        for interrupt in [false, true] {
            try await agent.reset()
            let call = try await agent.complete("What is the weather in Lagos?")
            #expect(call.functionCalls?.first?.name == "get_weather")
            if interrupt {
                let other = try await Mirage(configuration: MirageConfiguration(weightsPath: visionPath.path))
                #expect(await runtime.visionWeights == visionPath.path)
                _ = try await other.describe(image)
            }
            let response = try await agent.complete(#"["Clear in Lagos"]"#)
            #expect(response.type == "respond", "\(response)")
            if let baseline {
                #expect(response.functionCalls == baseline.functionCalls)
                #expect(response.reasoning == baseline.reasoning)
                #expect(response.confidence == baseline.confidence)
            }
            baseline = response
        }
        #expect(await runtime.loadedModels() == 7)
        #expect(try await speech.transcribe([Float](repeating: 0, count: Whistle.sampleRate)).text.isEmpty)
        // Vision after text and speech switches still answers the same.
        #expect(try await vision.describe(image).raw == description.raw)

        // A vision call and a vision reload during live transcription leave the stream intact;
        // the engine copies archives, so the loaded weights need no retained copy.
        let live = try speech.stream(options: AudioOptions(language: "en"))
        _ = try await live.process([Float](repeating: 0, count: Whistle.sampleRate))
        _ = try await vision.describe(image, options: DescribeOptions(sections: [.scene]))
        let reloaded = try await Mirage(configuration: MirageConfiguration(weightsPath: visionPath.path))
        #expect(await runtime.visionWeights == visionPath.path)
        #expect(try await reloaded.describe(image).raw == description.raw)
        let step = try await live.process([Float](repeating: 0, count: Whistle.sampleRate))
        #expect(step.received >= 1.9)
        _ = try await live.stop()

        // Wrong-kind archives are rejected before loading, in every direction.
        await #expect { try await Agent(configuration: Configuration(weightsPath: visionPath.path)) } throws: {
            $0.localizedDescription == "cactus: weights are not a recognized text model"
        }
        await #expect {
            try await Whistle(configuration: WhistleConfiguration(weightsPath: visionPath.path))
        } throws: { $0.localizedDescription == "cactus: weights are not a recognized speech model" }
        for path in [agent.session.weightsPath, speech.session.weightsPath] {
            await #expect { try await Mirage(configuration: MirageConfiguration(weightsPath: path)) } throws: {
                $0.localizedDescription == "cactus: weights are not a recognized vision model"
            }
        }
        #expect(await runtime.loadedModels() == 7)
        #expect(try await agent.complete("hello").success == true)
    }
}
