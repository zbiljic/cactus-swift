@testable import Cactus
import Foundation
import Testing

func address(_ function: some Any) -> UnsafeMutableRawPointer {
    unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
}

extension CactusFunctions {
    /// Fails every call; tests replace the functions they exercise.
    static let unused = Self(
        embed: { _, _ in -1 },
        transcribe: { _, _, _ in -1 },
        setAudio: { _ in },
        setThreads: { _ in },
        completeAudio: { _, _, _ in -1 },
        streamProcess: { _, _, _ in -1 },
        streamStop: { _ in -1 },
        describe: { _, _, _ in -1 },
        models: { 0 }
    )
}

/// Records cactus_set_threads calls, which a C function pointer cannot capture.
final class ThreadCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Int32] = []

    var values: [Int32] {
        lock.withLock { calls }
    }

    func append(_ count: Int32) {
        lock.withLock { calls.append(count) }
    }
}

let threadCalls = ThreadCalls()

/// The live transcription pair, checking the six-argument process ABI.
private func streamSymbols() -> [String: UnsafeMutableRawPointer] {
    let streamProcess: NativeAPI.StreamProcess = { pcm, count, language, keywords, output, capacity in
        guard
            let pcm, pcm[0] == 0.25, count == 2, let language, String(cString: language) == "en",
            let keywords, String(cString: keywords) == "Paris\nAda", capacity == 32 else { return -1 }
        output?[0] = 67
        return 3
    }
    let streamStop: NativeAPI.StreamStop = { output, capacity in
        guard capacity == 32 else { return -1 }
        output?[0] = 68
        return 0
    }
    return [
        "cactus_stream_transcribe_process": address(streamProcess),
        "cactus_stream_transcribe_stop": address(streamStop),
    ]
}

/// The needle_* symbols of the Needle 2 engine, or the cactus_* symbols of the Cactus engine.
func nativeSymbols(generation: Int) -> [String: UnsafeMutableRawPointer] {
    let initialize: NativeAPI.Initialize = { _, _, _ in 12 }
    let reset: NativeAPI.Reset = {}
    let load: NativeAPI.Load = { _, size in size == 4 ? 1 : -1 }
    let needle2: NativeAPI.Complete = { text, tokens, output, capacity in
        guard let text, String(cString: text) == "hello", tokens == 123, capacity == 32 else { return -1 }
        output?[0] = 65
        return 7
    }
    let cactus: NativeAPI.CompleteWithAudio = { text, pcm, samples, tokens, output, capacity in
        guard
            let text, String(cString: text) == "hello", pcm == nil, samples == 0,
            tokens == 123, capacity == 32 else { return -1 }
        output?[0] = 65
        return 7
    }
    let embed: NativeAPI.Embed = { text, pcm, samples, output, capacity in
        guard let text, String(cString: text) == "hello", pcm == nil, samples == 0 else { return -1 }
        guard let output else { return capacity == 0 ? 2 : -1 }
        guard capacity == 2 else { return -1 }
        output[0] = 0.25
        output[1] = -0.75
        return 2
    }
    let lastError: NativeAPI.LastError = {
        let message: StaticString = "native detail"
        return UnsafeRawPointer(message.utf8Start).assumingMemoryBound(to: CChar.self)
    }
    guard generation == 3 else {
        return [
            "needle_init": address(initialize), "needle_reset": address(reset), "needle_load": address(load),
            "needle_complete": address(needle2),
        ]
    }
    var symbols = [
        "cactus_init": address(initialize), "cactus_reset": address(reset), "cactus_load": address(load),
        "cactus_complete": address(cactus), "cactus_embed": address(embed), "cactus_last_error": address(lastError),
    ]
    let models: NativeAPI.Models = { 7 }
    let describe: NativeAPI.Describe = { _, _, _, _, _, _, _, _ in -1 }
    symbols["cactus_models"] = address(models)
    symbols["cactus_describe"] = address(describe)
    for name in ["cactus_transcribe", "cactus_set_audio"] {
        symbols[name] = address(reset) // Required, but not called here.
    }
    let setThreads: NativeAPI.SetThreads = { threadCalls.append($0) }
    symbols["cactus_set_threads"] = address(setThreads)
    symbols.merge(streamSymbols()) { _, new in new }
    return symbols
}

@Test(arguments: [2, 3])
func nativeCompletionABI(generation: Int) throws {
    var symbols = nativeSymbols(generation: generation)
    let api = try NativeAPI.bind(generation: generation) { symbols[$0] }
    var buffer = [CChar](repeating: 0, count: 32)
    #expect(buffer.withUnsafeMutableBufferPointer { api.complete("hello", 123, $0) } == 7)
    #expect(buffer[0] == 65)
    #expect(api.failure("test", code: -2, fallback: "buffer").localizedDescription
        == "cactus: test failed with code -2: \(generation == 3 ? "native detail" : "buffer")")
    if generation == 3 {
        let cactus = try #require(api.cactus)
        let before = threadCalls.values.count
        cactus.setThreads(3)
        cactus.setThreads(0)
        #expect(threadCalls.values.dropFirst(before).starts(with: [3, 0]))
        let embed = cactus.embed
        #expect(embed("hello", UnsafeMutableBufferPointer(start: nil, count: 0)) == 2)
        var vector = [Float](repeating: 0, count: 2)
        #expect(vector.withUnsafeMutableBufferPointer { embed("hello", $0) } == 2)
        #expect(vector == [0.25, -0.75])
        #expect(api.cactus?.models() == 7)
    } else {
        #expect(api.lastError == nil && api.cactus == nil)
        // A pre-4.0 Needle 3 library shares the four names with a six-argument completion.
        symbols["needle_models"] = symbols["needle_reset"] // Probed, never called.
        #expect { try NativeAPI.bind(generation: 2) { symbols[$0] } } throws: { error in
            error.localizedDescription
                == "cactus: unsupported native ABI: Needle 3 library is not the Needle 2 engine"
        }
        symbols["needle_models"] = nil
    }
    // Every function of the generation's ABI is required.
    for name in Array(symbols.keys) {
        let removed = symbols.removeValue(forKey: name)
        let engine = generation == 2 ? "Needle 2 engine" : "Cactus engine"
        #expect { try NativeAPI.bind(generation: generation) { symbols[$0] } } throws: { error in
            guard case let .unsupportedABI(message) = error as? CactusError else { return false }
            return message == "\(engine) is missing \(name)"
        }
        symbols[name] = removed
    }
    // The other generation's ABI is rejected.
    #expect { try NativeAPI.bind(generation: 5 - generation) { symbols[$0] } } throws: { error in
        if case .unsupportedABI = error as? CactusError {
            true
        } else {
            false
        }
    }
}

@Test
func nativeDiagnosticFallbacks() {
    var api = NativeAPI(initialize: { _, _, _ in 0 }, complete: { _, _, _ in 0 }, reset: {}, load: { _, _ in 0 })
    for detail: String? in [nil, "", " \n"] {
        api.lastError = { detail }
        #expect(api.failure("load", code: -1).localizedDescription == "cactus: load failed with code -1")
        #expect(api.failure("complete", code: -1, fallback: " buffer \n").localizedDescription
            == "cactus: complete failed with code -1: buffer")
    }
}

@Test
func setThreadsValidatesStoresAndApplies() async throws {
    // Before the engine loads, the count is kept for the load.
    let unloaded = NativeRuntime()
    try await Engine.setThreads(4, runtime: unloaded)
    #expect(await unloaded.threads == 4)

    let calls = ThreadCalls()
    var api = FakeNative().api
    var cactus = CactusFunctions.unused
    cactus.setThreads = { calls.append($0) }
    api.cactus = cactus
    let runtime = NativeRuntime(api: api)
    try await Engine.setThreads(2, runtime: runtime)
    try await Engine.setThreads(0, runtime: runtime)
    for bad in [-1, Int(Int32.max) + 1] {
        await #expect { try await Engine.setThreads(bad, runtime: runtime) } throws: { error in
            error.localizedDescription.contains("threads")
        }
    }
    #expect(calls.values == [2, 0])
    #expect(await runtime.threads == 0)

    // A count set before the engine loads is applied when it opens.
    let fake = api
    let opened = NativeRuntime { _, _ in fake }
    try await Engine.setThreads(3, runtime: opened)
    try await opened.initialize(Session(Configuration()), library: URL(fileURLWithPath: "/test/libcactus.dylib"))
    #expect(calls.values == [2, 0, 3])
}

extension NativeIntegrationTests {
    @Test
    func nativeThreads() async throws {
        // Weights keep the thread count they were loaded with, so load a copy of
        // the speech weights rather than the text weights other tests share.
        let path = try await Engine.fetchSpeechWeights(cacheDirectory: nil)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cact")
        try FileManager.default.copyItem(at: path, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        try await Engine.setThreads(1)
        let speech: Whistle
        do {
            speech = try await Whistle(configuration: WhistleConfiguration(weightsPath: copy.path))
            try await Engine.setThreads(0)
        } catch {
            try await Engine.setThreads(0)
            throw error
        }
        #expect(try await speech.transcribe([Float](repeating: 0, count: Whistle.sampleRate)).text.isEmpty)
    }
}
