@testable import Cactus
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

func makeImage(
    _ bytes: [UInt8],
    _ width: Int,
    _ height: Int,
    depth: Int = 8,
    channels: Int,
    alpha: CGImageAlphaInfo,
    space: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB),
    byteOrder: CGBitmapInfo = []
) throws -> CGImage {
    let bitsPerPixel = depth * channels
    let space = try #require(space)
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    return try #require(CGImage(
        width: width,
        height: height,
        bitsPerComponent: depth,
        bitsPerPixel: bitsPerPixel,
        bytesPerRow: width * bitsPerPixel / 8,
        space: space,
        bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(byteOrder),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
}

func encodeImage(_ image: CGImage, as type: UTType, orientation: Int? = nil) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
    if let orientation {
        properties[kCGImagePropertyOrientation] = orientation
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test
func rgbImageConvertsWithoutAlphaOrColorMatching() throws {
    let rgb: [UInt8] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]
    let rgba: [UInt8] = stride(from: 0, to: rgb.count, by: 3).flatMap { rgb[$0 ..< $0 + 3] + [0xFF] }
    let table = try makeImage(rgb, 2, 2, channels: 3, alpha: .none)
    let wide: [UInt8] = rgb.flatMap { [$0, $0] } // 16-bit big-endian components of 0x0A0A and so on.
    let bgra: [UInt8] = stride(from: 0, to: rgb.count, by: 3).flatMap { [rgb[$0 + 2], rgb[$0 + 1], rgb[$0], 0xFF] }
    let gray = CGColorSpaceCreateDeviceGray()
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)
    let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let palette = CGColorSpace(indexedBaseSpace: srgb, last: 3, colorTable: rgb)
    // swiftlint:disable:next large_tuple
    let cases: [(String, CGImage, [UInt8])] = try [
        ("RGB", table, rgb),
        ("RGBA", makeImage(rgba, 2, 2, channels: 4, alpha: .last), rgb),
        ("RGBX", makeImage(rgba, 2, 2, channels: 4, alpha: .noneSkipLast), rgb),
        ("BGRA", makeImage(bgra, 2, 2, channels: 4, alpha: .premultipliedFirst, byteOrder: .byteOrder32Little), rgb),
        ("16-bit", makeImage(wide, 2, 2, depth: 16, channels: 3, alpha: .none, byteOrder: .byteOrder16Big), rgb),
        // RGB values are kept as Pillow keeps them, without color matching.
        ("Display P3", makeImage(rgb, 2, 2, channels: 3, alpha: .none, space: p3), rgb),
        // Alpha is dropped and straight color kept, as Pillow's RGB conversion does.
        ("translucent", makeImage([200, 100, 50, 0x80], 1, 1, channels: 4, alpha: .last), [200, 100, 50]),
        ("premultiplied", makeImage([100, 50, 25, 0x80], 1, 1, channels: 4, alpha: .premultipliedLast), [199, 100, 50]),
        ("gray", makeImage([7, 9], 2, 1, channels: 1, alpha: .none, space: gray), [7, 7, 7, 9, 9, 9]),
        ("gray alpha", makeImage([7, 0x80, 9, 0], 2, 1, channels: 2, alpha: .last, space: gray), [7, 7, 7, 9, 9, 9]),
        ("indexed", makeImage([0, 1, 2, 3], 2, 2, channels: 1, alpha: .none, space: palette), rgb),
    ]
    for (name, image, expected) in cases {
        let converted = try RGBImage(image)
        #expect(converted.pixels == expected && converted.width * converted.height * 3 == expected.count, "\(name)")
    }
    // Lossless and lossy formats decode to the same packed RGB.
    for type in [UTType.png, .gif, .tiff, .jpeg, .bmp] {
        let decoded = try RGBImage(data: encodeImage(table, as: type))
        #expect(try decoded == RGBImage(width: 2, height: 2, pixels: rgb), "\(type)")
    }
    // Files keep straight color, even under fully transparent pixels.
    let translucent = try makeImage([200, 100, 50, 0, 10, 20, 30, 0x80, 1, 2, 3, 0xFF], 3, 1, channels: 4, alpha: .last)
    for type in [UTType.png, .tiff] {
        let decoded = try RGBImage(data: encodeImage(translucent, as: type))
        #expect(decoded.pixels == [200, 100, 50, 10, 20, 30, 1, 2, 3], "\(type)")
    }
    for invalid in [Data(), Data("not an image".utf8)] {
        #expect(throws: CactusError.self) { try RGBImage(data: invalid) }
    }
    #expect(throws: CactusError.self) { try RGBImage(contentsOf: URL(fileURLWithPath: "/nonexistent/image.png")) }
}

@Test
func rgbImageReadsLayoutsAndColorModels() throws {
    let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let gray = CGColorSpaceCreateDeviceGray()
    // A cropped image and a padded row stride read only their own pixels.
    let big = try makeImage(Array(0 ..< 48), 4, 4, channels: 3, alpha: .none)
    let cropped = try #require(big.cropping(to: CGRect(x: 1, y: 2, width: 2, height: 2)))
    #expect(try RGBImage(cropped).pixels == [27, 28, 29, 30, 31, 32, 39, 40, 41, 42, 43, 44])
    let provider = try #require(CGDataProvider(data: Data([1, 2, 3, 9, 9, 9, 9, 9, 4, 5, 6, 9, 9, 9, 9, 9]) as CFData))
    let padded = try #require(CGImage(
        width: 1,
        height: 2,
        bitsPerComponent: 8,
        bitsPerPixel: 24,
        bytesPerRow: 8,
        space: srgb,
        bitmapInfo: [],
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    #expect(try RGBImage(padded).pixels == [1, 2, 3, 4, 5, 6])
    // Bilevel scans expand to black and white.
    let bilevel = try makeImage([0b1010_0000], 8, 1, depth: 1, channels: 1, alpha: .none, space: gray)
    #expect(try RGBImage(bilevel).pixels == [255, 0, 255, 0, 0, 0, 0, 0].flatMap { [$0, $0, $0] })
    // Other color models are color matched to sRGB.
    let cmyk = try RGBImage(makeImage(
        [0, 0, 0, 0, 0, 0, 0, 0xFF], 2, 1, channels: 4, alpha: .none, space: CGColorSpaceCreateDeviceCMYK()
    ))
    #expect(cmyk.pixels.prefix(3).allSatisfy { $0 >= 230 } && cmyk.pixels.suffix(3).allSatisfy { $0 <= 80 }, "\(cmyk)")
}

@Test(arguments: 1 ... 8)
func rgbImageAppliesEXIFOrientation(orientation: Int) throws {
    let (width, height) = (3, 2)
    let pixels = (0 ..< width * height).flatMap { [UInt8($0 * 10), UInt8($0 * 10 + 1), UInt8($0 * 10 + 2)] }
    let stored = try makeImage(pixels, width, height, channels: 3, alpha: .none)
    let data = try encodeImage(stored, as: .png, orientation: orientation)
    // ImageIO's own transform is the reference for upright pixels.
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let upright = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
    ] as CFDictionary))
    let decoded = try RGBImage(data: data)
    #expect(try decoded == RGBImage(upright))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try RGBImage(contentsOf: file) == decoded)
    if orientation == 6 { // Rotated 90° clockwise: the bottom-left pixel comes first.
        #expect(decoded.width == 2 && decoded.height == 3 && decoded.pixels.prefix(6) == [30, 31, 32, 0, 1, 2])
    }
}

@Test
func maskJSONAndBitmap() throws {
    for (input, mask) in [
        ("[1,2,3,4,5,6]", Mask.polygons([[1, 2, 3, 4, 5, 6]])),
        ("[]", .polygons([])),
        ("[[1,2,3,4,5,6],[7,8,9,10,11,12]]", .polygons([[1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12]])),
        (#"{"size":[2,3],"counts":[1,2,3]}"#, .runLength(height: 2, width: 3, counts: [1, 2, 3])),
    ] {
        #expect(try JSONDecoder().decode(Mask.self, from: Data(input.utf8)) == mask)
    }
    // A bitmap missing its size or counts decodes as empty, as in Go, and does not decode to pixels.
    for (input, mask) in [
        ("{}", Mask.runLength(height: 0, width: 0, counts: [])),
        (#"{"size":[2,3]}"#, .runLength(height: 2, width: 3, counts: [])),
    ] {
        let decoded = try JSONDecoder().decode(Mask.self, from: Data(input.utf8))
        #expect(decoded == mask && decoded.bitmap() == nil)
    }
    for invalid in [#""mask""#, #"[1,"a"]"#, #"{"size":"x"}"#, #"{"size":[1],"counts":[1]}"#] {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Mask.self, from: Data(invalid.utf8)) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    for (mask, json) in [
        (Mask.polygons([[1, 2, 3, 4]]), "[[1,2,3,4]]"),
        (.runLength(height: 1, width: 1, counts: [0, 1]), #"{"counts":[0,1],"size":[1,1]}"#),
        (.polygons([]), "[]"),
    ] {
        #expect(try String(decoding: encoder.encode(mask), as: UTF8.self) == json)
    }
    // A 2x3 (height x width) mask in column-major runs: one background pixel,
    // three mask pixels, then two background pixels.
    #expect(Mask.runLength(height: 2, width: 3, counts: [1, 3, 2]).bitmap() == [0, 0xFF, 0, 0xFF, 0xFF, 0])
    for invalid in [
        Mask.polygons([[1, 2]]),
        .runLength(height: 2, width: 3, counts: [1, 3]),
        .runLength(height: 2, width: 3, counts: [1, 6]),
        .runLength(height: 2, width: 3, counts: [-1, 7]),
        .runLength(height: 0, width: 3, counts: []),
        .runLength(height: Int(Int32.max), width: Int(Int32.max), counts: [0]),
    ] {
        #expect(invalid.bitmap() == nil)
    }
}
