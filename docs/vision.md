# Vision

`Mirage` loads the checksum-pinned ~21.6 MB `mirage.cact` archive from
[Cactus-Compute/mirage](https://huggingface.co/Cactus-Compute/mirage) and runs on
the Cactus engine. Vision weights download only when requested; describing
images does not require text or speech weights.

## Describing images

```swift
import Cactus

let image = try RGBImage(contentsOf: URL(fileURLWithPath: "photo.png"))
let vision = try await Mirage()
let description = try await vision.describe(image)
for object in description.objects ?? [] {
    print(object.id, object.name, object.bbox ?? [], object.attributes ?? [:])
}
```

An `ImageDescription` has these sections, each nil when not requested:

- `scene`: attributes such as `background`, `lighting`, and `style`.
- `objects`: each with an `id`, a `name`, and the details listed below.
- `text`: recognized lines.
- `relations`: links between object IDs, such as `(2, "part_of", 5)`.
- `reasoning`: the model's short rationale.
- `regions` and `events`: left as `JSONValue`.

`raw` keeps the engine's JSON, including any part these types do not model. If
the JSON does not fit these types, `describe` throws
`CactusError.undecodableDescription`, which carries the JSON.

Coordinates are in a 0 to 1000 space over the image width and height:

- `bbox` is `[x0, y0, x1, y1]`.
- `point` is `[x, y]`.
- Polygon masks are flattened `x0, y0, x1, y1, ...` outlines.

Multiply x by `width / 1000` and y by `height / 1000` for pixels. `score`,
`position` (such as `left` or `top`), and `attributes` (the engine's
`description`, such as `color` and `shape`) complete each object.

## Options

`DescribeOptions` narrows the response. Nil values keep the engine defaults;
an empty `language`, `keywords`, or `extra` adds nothing.

- `sections`: the sections to return, such as `.objects` and `.text`.
- `fields`: the per-item details: `.bbox`, `.score`, `.point`, `.mask`,
  `.position`, and `.description`. By default every detail except `.point` is
  returned. An empty array returns only IDs, names, and text strings.
- `maskFormat`:
  - `.largest` and `.merged` give one polygon.
  - `.polygons` gives one polygon per part.
  - `.bitmap` gives `Mask.runLength`, a COCO-style run-length encoding over the
    image's pixels. `Mask.bitmap()` decodes it to row-major bytes, `0xff` for
    mask pixels.
- `confidence` and `textConfidence`: score thresholds in `(0, 1]`.
- `maxObjects`, `maxTextLines`, and `maxTokens`: positive limits on the response.
- `nms`: turns suppression of overlapping detections on or off.
- `language`: names and descriptions in `de`, `fr`, `es`, `it`, `nl`, or `pl`
  instead of English.
- `keywords`: words and phrases to favor.
- `extra`: passes other `cactus_describe` options, such as `keyword_bias`,
  `mask_threshold`, or `mask_tolerance`, verbatim. It cannot repeat an option
  that has a property.

The library checks thresholds and limits before calling the engine. The engine
validates names, languages, and the remaining ranges, and reports invalid
options as `CactusError.nativeFailure` with a detail that names the problem.
Sections, fields, and mask formats accept raw values, such as
`MaskFormat(rawValue: "...")`, for engine options this library does not name.

## Forms

`extract` fills an ordered array of form fields from an image and returns the
values by field name. Fields are filled in order, so later fields can depend on
earlier ones.

```swift
let values = try await vision.extract(image, form: [
    .choice("type", ["invoice", "receipt", "photo"]),
    .count("circles", 0 ... 5),
    .text("title", maxLength: 32),
])
print(values["type"]?.value ?? .null, values["type"]?.probabilities ?? [:])
```

The field kinds return:

- `choice` and `count`: `probabilities` for every option, plus `-` for no value.
- `text`: a single `probability`.

`value` is a `JSONValue`: `.string` for choices and text, and a number
(`.integer`) for counts. A choice the model declines is `.null`; a declined text
field is `.string("-")`. `FormField(name:schema:)` passes other engine field
schemas through verbatim.

The published model answers best with field names that name a visible
property, such as `type` or `circle color`. Text fields often repeat the field
name or return `-`. Check the probabilities before acting on a value.

## Image input

`describe` and `extract` take an `RGBImage`: packed 8-bit RGB
(`width * height * 3` bytes, row-major, no padding), which reaches the engine
without conversion or copying. Build one in three ways:

- `RGBImage(width:height:pixels:)` wraps packed RGB you already have.
- `RGBImage(_:)` converts a `CGImage`.
- `RGBImage(data:)` and `RGBImage(contentsOf:)` decode the primary image of any
  format ImageIO reads, such as PNG, JPEG, HEIC, TIFF, or GIF (its first frame).

Conversion follows Pillow's RGB conversion, as upstream does:

- Alpha is dropped and straight color is kept; nothing is composited. Composite
  translucent images onto a background first if that matters. A `CGImage` with
  premultiplied alpha has lost the color of fully transparent pixels, which
  convert to black.
- RGB and gray values are kept as stored, without color matching to sRGB.
  Other color models, such as CMYK, are converted to sRGB.

### EXIF orientation

Many phone and camera photos store pixels sideways and record the rotation
only in the EXIF `Orientation` tag. Like upstream's Python package,
`RGBImage(data:)` and `RGBImage(contentsOf:)` read that tag and rotate or flip
the pixels upright, so boxes and positions describe the upright photo.

A `CGImage` carries no orientation. `RGBImage(_:)` converts its pixels as
stored, so apply the orientation yourself when a `CGImage` comes from a source
that records it separately. Boxes are always relative to the pixels you pass.

## Runtime and custom weights

Mirage shares one serialized Cactus engine runtime and library path with the
other models the engine runs, such as Needle 3 text and Whistle speech. The
engine holds one model of each kind, so they can all be loaded at once.

- Loading or switching vision weights preserves the loaded text and speech
  models and the active text conversation.
- Vision calls and vision weight loads during a live transcription leave the
  stream intact.
- Task cancellation cannot interrupt native inference already in progress.

`MirageConfiguration` accepts `weightsPath`, `libraryPath`, `cacheDirectory`,
and `bufferSize`. `weightsPath` selects a trusted custom vision archive; library
and cache selection follow the [engine configuration](../README.md#engine-downloads-and-caching).
`bufferSize` bounds the JSON response (16 MiB by default). A response that does
not fit throws `CactusError.nativeFailure` with the engine's detail.

The shared `.cact` header alone does not distinguish vision archives from text
or speech archives. Each loading path checks the recognized manifest layout
before loading, and wrong-kind or unknown-kind archives are rejected without
touching the engine. The vision classifier accepts the published 36-value
vision manifest; a future layout requires a library update. After loading,
`Mirage` also confirms that the engine reports a vision model.

`close` releases a `Mirage`; later calls throw `CactusError.closed`. Loaded
vision weights stay in the engine for other `Mirage` values.

## Offline setup

`try await Engine.fetchMirage(cacheDirectory: cacheDirectory)` prepares the
engine and vision weights without fetching text or speech weights. Its
`platform` parameter selects the target macOS architecture. Preserve the
`.sha256` markers and use the same cache directory in `MirageConfiguration`.
