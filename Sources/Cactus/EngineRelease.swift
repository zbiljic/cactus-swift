import Foundation

/// One file published on Hugging Face at a fixed commit, pinned by size and checksum.
struct EngineArtifact: Sendable {
    /// The installed file name in the cache directory.
    let name: String
    let repository: String
    let revision: String
    let path: String
    let size: Int
    let checksum: String
    /// The library inside a wheel; nil for weights.
    var archivePath: String?

    var url: String {
        "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)"
    }
}

/// One downloadable release: the engine libraries per platform and, when the
/// engine needs them, the base weights it loads.
struct EngineRelease: Sendable {
    let generation: Int
    let version: String
    let libraryName: String
    private let libraries: [Engine.Platform: EngineArtifact]
    /// The archive loaded with `cactus_load`; nil for Needle 2, whose engine embeds its model.
    let weights: EngineArtifact?

    static let needle2 = Self(
        generation: 2,
        version: "2.0.4",
        libraryName: "libneedle.dylib",
        libraries: [
            .darwinARM64: needle2Wheel(
                "macosx_11_0_arm64",
                size: 13_323_841,
                checksum: "abae4cca0a4d84ec73da4bde18803b9be812a9209e48fb7fa372002ebaa60265"
            ),
            .darwinAMD64: needle2Wheel(
                "macosx_11_0_x86_64",
                size: 13_217_806,
                checksum: "071e93d996021b4f6b5bee055777cd81be9f6963d2565115ec461b9f71c7245e"
            ),
        ],
        weights: nil
    )

    /// The Cactus engine, which runs Needle 3, Whistle and Mirage.
    static let needle3 = Self(
        generation: 3,
        version: Engine.version,
        libraryName: "libcactus.dylib",
        libraries: [
            .darwinARM64: cactusWheel(
                "macosx_11_0_arm64",
                size: 720_571,
                checksum: "782a43480285bf36e7dda947f50496dc597dceb26a8f8f9406d89fbe7ce96a1c"
            ),
            .darwinAMD64: cactusWheel(
                "macosx_11_0_x86_64",
                size: 780_485,
                checksum: "ba674f62f53d91328d0b925ba9c179c15f6fef04865b334ac9c505d83d5932da"
            ),
        ],
        weights: EngineArtifact(
            name: "needle3.cact",
            repository: "Cactus-Compute/needle3",
            revision: "d6c7d6a2e9655505e0f8e23339356dd1705900eb",
            path: "needle3.cact",
            size: 35_335_380,
            checksum: "c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38"
        )
    )

    /// Speech weights run on the Cactus engine and share its cache directory.
    static let speechWeights = EngineArtifact(
        name: "whistle.cact",
        repository: "Cactus-Compute/whistle",
        revision: "741118687e1f008f06d1351a402a731274789790",
        path: "whistle.cact",
        size: 16_919_407,
        checksum: "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb"
    )

    static let whistle = Self(
        generation: 3,
        version: needle3.version,
        libraryName: needle3.libraryName,
        libraries: needle3.libraries,
        weights: speechWeights
    )

    /// Vision weights run on the Cactus engine and share its cache directory.
    static let visionWeights = EngineArtifact(
        name: "mirage.cact",
        repository: "Cactus-Compute/mirage",
        revision: "76c1e9e53381aca8fc3843c636216c96ff220122",
        path: "mirage.cact",
        size: 21_611_043,
        checksum: "4249a0f7515272ff76b9414bec17d7e7daf84b15b66c7fb4f17fce1e66f9f237"
    )

    static let mirage = Self(
        generation: 3,
        version: needle3.version,
        libraryName: needle3.libraryName,
        libraries: needle3.libraries,
        weights: visionWeights
    )

    private static func needle2Wheel(_ tag: String, size: Int, checksum: String) -> EngineArtifact {
        EngineArtifact(
            name: "libneedle.dylib",
            repository: "Cactus-Compute/needle2",
            revision: "32e9e3a93b205f786929697446ae669cf0a84579",
            path: "python/cactus_needle-2.0.4-py3-none-\(tag).whl",
            size: size,
            checksum: checksum,
            archivePath: "needle/libneedle.dylib"
        )
    }

    /// Sizes and checksums come from releases/4.0.0/manifest.json (sha256
    /// b6a39fb21bc77780c029c45d4cc206b60f883146fa2dbc28bfcc9995fe72b871).
    private static func cactusWheel(_ tag: String, size: Int, checksum: String) -> EngineArtifact {
        EngineArtifact(
            name: "libcactus.dylib",
            repository: "Cactus-Compute/cactus",
            revision: "1a028f5a3972b67dd8d8752f882113d475e7ec4c",
            path: "releases/\(Engine.version)/python/cactus_runtime-\(Engine.version)-py3-none-\(tag).whl",
            size: size,
            checksum: checksum,
            archivePath: "cactus/libcactus.dylib"
        )
    }

    /// Selects 2 or 3; zero defaults to 3.
    init(_ generation: Int) throws {
        switch generation {
        case 2: self = .needle2
        case 0, 3: self = .needle3
        default: throw CactusError.unsupportedGeneration("unsupported generation \(generation); want 2 or 3")
        }
    }

    private init(
        generation: Int,
        version: String,
        libraryName: String,
        libraries: [Engine.Platform: EngineArtifact],
        weights: EngineArtifact?
    ) {
        self.generation = generation
        self.version = version
        self.libraryName = libraryName
        self.libraries = libraries
        self.weights = weights
    }

    func library(platform: Engine.Platform) throws -> EngineArtifact {
        guard let library = libraries[platform] else {
            throw CactusError.download("no \(version) engine build for \(platform.rawValue)")
        }
        return library
    }
}
