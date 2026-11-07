import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Packed 8-bit RGB: `width * height` pixels in row-major order, three bytes per
/// pixel, without row padding. Mirage passes `pixels` to the engine without
/// converting or copying them.
public struct RGBImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    /// Wraps packed RGB, which must hold exactly `width * height * 3` bytes.
    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        try Self.validate(width: width, height: height)
        guard pixels.count == width * height * 3 else {
            throw CactusError.invalidInput(
                "RGB image has \(pixels.count) bytes; want \(width * height * 3) for \(width)x\(height)"
            )
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Converts the pixels of `image` as stored. Alpha is dropped as Pillow's RGB
    /// conversion drops it: straight color is kept and nothing is composited.
    /// RGB and gray values are kept without color matching, as Pillow does; other
    /// color models are converted to sRGB. A `CGImage` has no EXIF orientation;
    /// `init(data:)` applies it.
    public init(_ image: CGImage) throws {
        let (width, height) = (image.width, image.height)
        try Self.validate(width: width, height: height)
        let space = image.colorSpace
        let gray = space?.model == .monochrome
        let target: CGColorSpace? = switch space?.model {
        case .rgb?, .monochrome?: space
        case .indexed? where space?.baseColorSpace?.model == .rgb: space?.baseColorSpace
        default: CGColorSpace(name: CGColorSpace.sRGB)
        }
        guard
            let target,
            let format = vImage_CGImageFormat(
                bitsPerComponent: 8,
                bitsPerPixel: gray ? 16 : 32,
                colorSpace: target,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
            ) else { throw CactusError.invalidInput("unsupported image color space") }
        var source: vImage_Buffer
        do {
            source = try vImage_Buffer(cgImage: image, format: format)
        } catch {
            throw CactusError.invalidInput("convert image to RGB: \(error)")
        }
        defer { source.free() }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        let status = rgb.withUnsafeMutableBytes { output in
            if gray {
                let pixels = output.bindMemory(to: UInt8.self)
                var index = 0
                for line in 0 ..< height {
                    let row = source.data.advanced(by: line * source.rowBytes).assumingMemoryBound(to: UInt8.self)
                    for column in 0 ..< width {
                        pixels[index] = row[column * 2]
                        pixels[index + 1] = row[column * 2]
                        pixels[index + 2] = row[column * 2]
                        index += 3
                    }
                }
            } else {
                var destination = vImage_Buffer(
                    data: output.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 3
                )
                return vImageConvert_RGBA8888toRGB888(&source, &destination, vImage_Flags(kvImageNoFlags))
            }
            return kvImageNoError
        }
        guard status == kvImageNoError
        else { throw CactusError.invalidInput("convert image to RGB: vImage error \(status)") }
        self.width = width
        self.height = height
        pixels = rgb
    }

    /// Decodes the primary image of any format ImageIO reads, such as PNG, JPEG,
    /// HEIC, TIFF or GIF (its first frame), and rotates or flips it upright by its
    /// EXIF orientation, as upstream does.
    public init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CactusError.invalidInput("decode image: unsupported or invalid image data")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw CactusError.invalidInput("decode image: unsupported or invalid image data")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        try self.init(image)
        self = oriented(orientation)
    }

    /// Reads and decodes an image file; see `init(data:)`.
    public init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CactusError.invalidInput("read image: \(error.localizedDescription)")
        }
        try self.init(data: data)
    }

    private struct Walk {
        let start: Int
        let column: Int
        let row: Int
    }

    private init(uncheckedWidth width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Whole images up to `Int32.max` bytes, as the native ABI takes them.
    private static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw CactusError.invalidInput("image is \(width)x\(height); want positive dimensions")
        }
        guard height <= Int(Int32.max) / 3 / width else {
            throw CactusError.invalidInput("image is \(width)x\(height); want at most \(Int(Int32.max) / 3) pixels")
        }
    }

    /// Applies an EXIF orientation (1 to 8) to stored pixels, as Pillow's
    /// `ImageOps.exif_transpose` does. Other values leave the image unchanged.
    func oriented(_ orientation: Int) -> Self {
        guard (2 ... 8).contains(orientation) else { return self }
        // The source pixel of an output pixel is start + column * walk.column + row * walk.row.
        let walk = switch orientation {
        case 2: Walk(start: width - 1, column: -1, row: width) // Mirror horizontally.
        case 3: Walk(start: height * width - 1, column: -1, row: -width) // Rotate 180°.
        case 4: Walk(start: (height - 1) * width, column: 1, row: -width) // Mirror vertically.
        case 5: Walk(start: 0, column: width, row: 1) // Transpose.
        case 6: Walk(start: (height - 1) * width, column: -width, row: 1) // Rotate 90° clockwise.
        case 7: Walk(start: height * width - 1, column: -width, row: -1) // Transverse.
        default: Walk(start: width - 1, column: width, row: -1) // Rotate 90° counterclockwise.
        }
        let (outputWidth, outputHeight) = orientation >= 5 ? (height, width) : (width, height)
        var output = [UInt8](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                var index = 0
                for row in 0 ..< outputHeight {
                    for column in 0 ..< outputWidth {
                        let source = (walk.start + column * walk.column + row * walk.row) * 3
                        output[index] = input[source]
                        output[index + 1] = input[source + 1]
                        output[index + 2] = input[source + 2]
                        index += 3
                    }
                }
            }
        }
        return Self(uncheckedWidth: outputWidth, height: outputHeight, pixels: output)
    }
}
