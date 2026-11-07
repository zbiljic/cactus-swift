@testable import Cactus
import Foundation
import Testing

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: url.lastPathComponent == "status" ? 503 : 200,
                httpVersion: nil,
                headerFields: url.lastPathComponent == "oversize"
                    ? ["Content-Length": "\(Engine.maximumArtifactSize + 1)"] : nil
            )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("verified bytes".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubArtifact(_ path: String = "ok", payload: Data, checksum: String? = nil) -> EngineArtifact {
    EngineArtifact(
        name: "needle3.cact",
        repository: "Cactus-Compute/test",
        revision: "test",
        path: path,
        size: payload.count,
        checksum: checksum ?? Engine.digest(payload)
    )
}

@Test
func verifiesDownloadsAndRejectsHTTPSizeAndHashErrors() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let payload = Data("verified bytes".utf8)
    let checksum = Engine.digest(payload)
    let url = try #require(URL(string: "https://needle.test/ok"))
    #expect(try await Engine.downloadAttempt(
        URLRequest(url: url), size: payload.count, checksum: checksum, session: session
    ) == payload)
    // Each failure is a stub path, the pinned size, and the expected error.
    // swiftlint:disable:next large_tuple
    let failures: [(request: String, size: Int, message: String)] = [
        ("status", payload.count, "HTTP 503"),
        ("oversize", payload.count, "server reports \(Engine.maximumArtifactSize + 1) bytes"),
        ("ok", payload.count - 1, "exceeds \(payload.count - 1) bytes"),
        ("ok", payload.count + 1, "got \(payload.count) bytes"),
        ("checksum", payload.count, "checksum mismatch"),
    ]
    for failure in failures {
        let url = try #require(URL(string: "https://needle.test/\(failure.request)"))
        await #expect {
            try await Engine.downloadAttempt(
                URLRequest(url: url),
                size: failure.size,
                checksum: failure.request == "checksum" ? "wrong" : checksum,
                session: session
            )
        } throws: { $0.localizedDescription.contains(failure.message) }
    }
}

@Test
func cacheIntegrityAndFailedDownloadPreserveExistingLibrary() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("libneedle.dylib")
    let checksum = try EngineRelease(2).library(platform: .current).checksum
    let data = Data("existing library".utf8)
    try data.write(to: target)
    #expect(try Engine.cached(generation: 2, cacheDirectory: directory) == target)
    #expect(!Engine.verifiedCache(target, checksum: checksum))
    let marker = "\(checksum)\n\(Engine.digest(data))\n"
    try marker.write(to: target.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
    #expect(Engine.verifiedCache(target, checksum: checksum))
    #expect(!Engine.verifiedCache(target, checksum: "different architecture"))
    try Data("modified".utf8).write(to: target)
    #expect(!Engine.verifiedCache(target, checksum: checksum))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    await #expect(throws: CactusError.self) {
        try await Engine.fetch(generation: 2, cacheDirectory: directory, session: session)
    }
    #expect(try Data(contentsOf: target) == Data("modified".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
        "libneedle.dylib", "libneedle.dylib.sha256",
    ])
}

@Test
func extractsOnlyTheLibraryMember() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = directory.appendingPathComponent("needle")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = Data("library bytes".utf8)
    try payload.write(to: source.appendingPathComponent("libneedle.dylib"))
    try Data("ignored".utf8).write(to: source.appendingPathComponent("other.txt"))
    let archive = directory.appendingPathComponent("test.whl")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = directory
    process.arguments = ["-q", archive.path, "needle/libneedle.dylib", "needle/other.txt"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(try Engine
        .extractLibrary(archive: archive, temporary: directory, member: "needle/libneedle.dylib") == payload)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("other.txt").path))
}

@Test
func downloadsAndVerifiesBaseWeightsAndIsolatesGenerationCaches() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let payload = Data("verified bytes".utf8)
    let artifact = stubArtifact(payload: payload)
    let target = try await Engine.download(artifact: artifact, directory: directory, session: session)
    #expect(try Data(contentsOf: target) == payload)
    #expect(Engine.verifiedCache(target, checksum: artifact.checksum))
    // A valid cache works even with an unreachable URL.
    let cached = stubArtifact("status", payload: payload)
    #expect(try await Engine.download(artifact: cached, directory: directory, session: session) == target)
    let bad = stubArtifact(payload: payload, checksum: "wrong")
    await #expect(throws: CactusError.self) {
        try await Engine.download(artifact: bad, directory: directory, session: session)
    }
    #expect(try Data(contentsOf: target) == payload)
    for generation in [2, 3] {
        let release = try EngineRelease(generation)
        let path = directory.appendingPathComponent(release.libraryName)
        try payload.write(to: path)
        #expect(try Engine.cached(generation: generation, cacheDirectory: directory) == path)
        #expect(try Engine.directory(release: release, platform: .current, override: nil).path
            .contains("/\(release.version)/"))
        let (repository, wheel, archive) = generation == 2
            ? ("Cactus-Compute/needle2", "python/cactus_needle-2.0.4-py3-none-", "needle/libneedle.dylib")
            : (
                "Cactus-Compute/cactus",
                "releases/4.0.0/python/cactus_runtime-4.0.0-py3-none-",
                "cactus/libcactus.dylib"
            )
        for platform in Engine.Platform.allCases {
            let library = try release.library(platform: platform)
            #expect(library.name == release.libraryName && library.archivePath == archive)
            #expect(library.repository == repository && library.path.hasPrefix(wheel))
            #expect(library.url == "https://huggingface.co/\(repository)/resolve/\(library.revision)/\(library.path)")
            #expect(library.revision.count == 40 && library.checksum.count == 64)
            #expect((1 ... Engine.maximumArtifactSize).contains(library.size))
        }
    }
    #expect(try EngineRelease(3).libraryName == "libcactus.dylib")
    #expect(try Engine.version(for: 0) == "4.0.0")
    #expect(try Engine.version(for: 2) == "2.0.4")
    for weights in try [EngineRelease(3).weights, EngineRelease.speechWeights].map({ try #require($0) }) {
        #expect(weights.revision.count == 40 && weights.checksum.count == 64)
        #expect((1 ... Engine.maximumArtifactSize).contains(weights.size))
        #expect(weights
            .url == "https://huggingface.co/\(weights.repository)/resolve/\(weights.revision)/\(weights.name)")
    }
    #expect(try EngineRelease(3).weights?.repository == "Cactus-Compute/needle3")
    #expect(try EngineRelease(2).weights == nil)
    #expect(try EngineRelease.whistle.library(platform: .current).url == EngineRelease(3).library(platform: .current)
        .url)
    for generation in [-1, 1, 4] {
        #expect(throws: CactusError.self) { try Engine.cached(generation: generation) }
        await #expect(throws: CactusError.self) { try await Engine.fetch(generation: generation) }
    }
}

@Test
func whistleFetchUsesVerifiedCacheWithoutTextWeights() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try EngineRelease(3).library(platform: .current)
    for artifact in [library, EngineRelease.speechWeights] {
        let target = directory.appendingPathComponent(artifact.name)
        let data = artifact.name == "whistle.cact" ? testWeights(speech: true) : Data("library".utf8)
        try data.write(to: target)
        try "\(artifact.checksum)\n\(Engine.digest(data))\n".write(
            to: target.appendingPathExtension("sha256"), atomically: true, encoding: .utf8
        )
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    #expect(try await Engine.fetchWhistle(cacheDirectory: directory, session: session)
        == directory.appendingPathComponent(library.name))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("needle3.cact").path))
    #expect(EngineRelease.speechWeights.url.contains("/Cactus-Compute/whistle/resolve/"))
    #expect(EngineRelease.whistle.weights?.name == "whistle.cact")
}

/// Downloads every pinned macOS engine wheel and both weights archives from Hugging Face.
/// It loads the engines from a temporary cache and keeps them mapped, so run it in a
/// separate `swift test` invocation from NativeIntegrationTests, as the mise tasks do.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CACTUS_ARTIFACT_TEST"] == "1"))
struct PinnedArtifactTests {
    @Test
    func pinnedArtifactsDownloadAndVerify() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for generation in [2, 3] {
            let release = try EngineRelease(generation)
            for platform in Engine.Platform.allCases {
                let cache = directory.appendingPathComponent("\(generation)-\(platform.rawValue)")
                let library = try await Engine.fetchLibrary(release, platform: platform, cacheDirectory: cache)
                let data = try Data(contentsOf: library)
                // Mach-O 64-bit magic, little-endian.
                #expect(data.prefix(4) == Data([0xCF, 0xFA, 0xED, 0xFE]), "\(library.path)")
                if platform == .current {
                    let api = try NativeAPI.open(library.path, generation: generation)
                    #expect((api.cactus != nil) == (generation == 3))
                    // The other generation's ABI is rejected.
                    #expect { try NativeAPI.open(library.path, generation: 5 - generation) } throws: { error in
                        if case .unsupportedABI = error as? CactusError {
                            true
                        } else {
                            false
                        }
                    }
                }
            }
        }
        let weights = directory.appendingPathComponent("weights")
        for (artifact, path) in try await [
            (#require(EngineRelease.needle3.weights), Engine.fetchWeights(of: .needle3, cacheDirectory: weights)),
            (EngineRelease.speechWeights, Engine.fetchSpeechWeights(cacheDirectory: weights)),
        ] {
            let path = try #require(path)
            let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize
            #expect(size == artifact.size, "\(artifact.name)")
        }
    }
}
