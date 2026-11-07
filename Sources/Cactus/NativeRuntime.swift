import Darwin
import Foundation

struct NativeAPI: Sendable {
    typealias Initialize = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Int32
    typealias Complete = @convention(c) (
        UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32
    ) -> Int32
    typealias CompleteWithAudio = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<Float>?, Int32, Int32, UnsafeMutablePointer<CChar>?, Int32
    ) -> Int32
    typealias Transcribe = @convention(c) (
        UnsafePointer<Float>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32,
        UnsafeMutablePointer<CChar>?, Int32
    ) -> Int32
    typealias StreamProcess = @convention(c) (
        UnsafePointer<Float>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32
    ) -> Int32
    typealias StreamStop = @convention(c) (UnsafeMutablePointer<CChar>?, Int32) -> Int32
    typealias SetAudio = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Void
    typealias Reset = @convention(c) () -> Void
    typealias Load = @convention(c) (UnsafeRawPointer?, UInt64) -> Int32
    typealias LastError = @convention(c) () -> UnsafePointer<CChar>?
    typealias Embed = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<Float>?, Int32
    ) -> Int32

    let initialize: @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>?) -> Int32
    let complete: @Sendable (String, Int32, UnsafeMutableBufferPointer<CChar>) -> Int32
    let reset: @Sendable () -> Void
    let load: @Sendable (UnsafeRawPointer, UInt64) -> Int32

    var lastError: (@Sendable () -> String?)?
    /// The functions only the Cactus engine exports; nil for the Needle 2 engine.
    var cactus: CactusFunctions?

    /// The Needle 2 engine's needle_* ABI: it embeds its model and completes with four arguments.
    static let needle2Symbols = ["init", "complete", "reset", "load"]

    /// The cactus_* ABI that the Cactus engine exports in full. cactus_describe is
    /// bound only when vision support needs it.
    static let cactusSymbols = [
        "load", "models", "last_error", "init", "complete", "set_audio", "reset",
        "embed", "transcribe", "stream_transcribe_process", "stream_transcribe_stop",
    ]

    static func open(_ path: String, generation: Int) throws -> Self {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw CactusError.native("load library: \(String(cString: dlerror()))")
        }
        do {
            // The engine owns process-global pointers; keep it mapped for process lifetime.
            return try bind(generation: generation) { dlsym(handle, $0) }
        } catch {
            dlclose(handle)
            throw error
        }
    }

    /// Binds the ABI of a generation: needle_* for the Needle 2 engine and cactus_*
    /// for the Cactus engine that runs Needle 3 and Whistle. A library missing any
    /// function of that ABI is rejected.
    static func bind(generation: Int, resolve: @escaping (String) -> UnsafeMutableRawPointer?) throws -> Self {
        let needle2 = generation == 2
        let function = needle2
            ? Symbols(engine: "Needle 2 engine", prefix: "needle_", resolve: resolve)
            : Symbols(engine: "Cactus engine", prefix: "cactus_", resolve: resolve)
        for name in needle2 ? needle2Symbols : cactusSymbols {
            _ = try function(name, as: UnsafeMutableRawPointer.self)
        }
        // Needle 3 libraries before Cactus 4 also export the four Needle 2 names,
        // but with a six-argument needle_complete. needle_models identifies them.
        if needle2, resolve("needle_models") != nil {
            throw CactusError.unsupportedABI("Needle 3 library is not the Needle 2 engine")
        }
        let initialize = try function("init", as: Initialize.self)
        let reset = try function("reset", as: Reset.self)
        let load = try function("load", as: Load.self)
        let complete: @Sendable (String, Int32, UnsafeMutableBufferPointer<CChar>) -> Int32
        if needle2 {
            let needle = try function("complete", as: Complete.self)
            complete = { text, tokens, buffer in
                text.withCString { needle($0, tokens, buffer.baseAddress, Int32(buffer.count)) }
            }
        } else {
            let cactus = try function("complete", as: CompleteWithAudio.self)
            complete = { text, tokens, buffer in
                text.withCString { cactus($0, nil, 0, tokens, buffer.baseAddress, Int32(buffer.count)) }
            }
        }
        var api = Self(
            initialize: { initialize($0, $1, $2) },
            complete: complete,
            reset: { reset() },
            load: { load($0, $1) }
        )
        guard !needle2 else { return api }
        let lastError = try function("last_error", as: LastError.self)
        api.lastError = { lastError().map { String(cString: $0) } }
        api.cactus = try CactusFunctions(function)
        return api
    }

    /// Resolves one engine's prefixed symbols, rejecting a library that lacks one.
    struct Symbols {
        let engine: String
        let prefix: String
        let resolve: (String) -> UnsafeMutableRawPointer?

        func callAsFunction<T>(_ name: String, as _: T.Type) throws -> T {
            guard let address = resolve(prefix + name) else {
                throw CactusError.unsupportedABI("\(engine) is missing \(prefix)\(name)")
            }
            return unsafeBitCast(address, to: T.self)
        }
    }

    func output(_ operation: String, code: Int32, buffer: [CChar]) throws -> Data {
        let end = buffer.firstIndex(of: 0)
        let bytes = buffer.prefix(end ?? buffer.count).map { UInt8(bitPattern: $0) }
        guard code >= 0 else {
            throw failure(operation, code: code, fallback: String(decoding: bytes, as: UTF8.self))
        }
        guard end != nil else { throw CactusError.native("engine response exceeds buffer") }
        return Data(bytes)
    }

    /// Read the process-global error before any other native call can replace it.
    func failure(_ operation: String, code: Int32, fallback: String = "") -> CactusError {
        let diagnostic = (lastError?() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = diagnostic.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : diagnostic
        return .nativeFailure(operation: operation, code: code, detail: detail)
    }
}

/// The Cactus engine functions beyond the text ABI it shares with Needle 2:
/// embeddings, speech and live transcription.
struct CactusFunctions: Sendable {
    typealias StreamProcessCall = @Sendable (
        UnsafeBufferPointer<Float>,
        AudioOptions,
        UnsafeMutableBufferPointer<CChar>
    ) -> Int32

    var embed: @Sendable (String, UnsafeMutableBufferPointer<Float>) -> Int32
    var transcribe: @Sendable (UnsafeBufferPointer<Float>, AudioOptions, UnsafeMutableBufferPointer<CChar>) -> Int32
    var setAudio: @Sendable (AudioOptions) -> Void
    var completeAudio: @Sendable (UnsafeBufferPointer<Float>, Int32, UnsafeMutableBufferPointer<CChar>) -> Int32
    var streamProcess: StreamProcessCall
    var streamStop: @Sendable (UnsafeMutableBufferPointer<CChar>) -> Int32
}

extension CactusFunctions {
    init(_ function: NativeAPI.Symbols) throws {
        let embed = try function("embed", as: NativeAPI.Embed.self)
        let complete = try function("complete", as: NativeAPI.CompleteWithAudio.self)
        let transcribe = try function("transcribe", as: NativeAPI.Transcribe.self)
        let setAudio = try function("set_audio", as: NativeAPI.SetAudio.self)
        let streamProcess = try function("stream_transcribe_process", as: NativeAPI.StreamProcess.self)
        let streamStop = try function("stream_transcribe_stop", as: NativeAPI.StreamStop.self)
        self.init(
            embed: { text, output in
                text.withCString { embed($0, nil, 0, output.baseAddress, Int32(output.count)) }
            },
            transcribe: { pcm, options, output in
                options.withCStringOptions {
                    transcribe(pcm.baseAddress, Int32(pcm.count), $0, $1, $2, output.baseAddress, Int32(output.count))
                }
            },
            setAudio: { options in options.withCStringOptions { setAudio($0, $1, $2) } },
            completeAudio: { pcm, tokens, output in
                complete(nil, pcm.baseAddress, Int32(pcm.count), tokens, output.baseAddress, Int32(output.count))
            },
            streamProcess: { pcm, options, output in
                options.withCStringOptions { language, keywords, _ in
                    streamProcess(
                        pcm.baseAddress, Int32(pcm.count), language, keywords, output.baseAddress, Int32(output.count)
                    )
                }
            },
            streamStop: { output in streamStop(output.baseAddress, Int32(output.count)) }
        )
    }
}

/// One actor per generation serializes its global C engine; independent
/// same-generation engines need separate processes.
actor NativeRuntime {
    /// Caps text vectors at 4 MiB; raise it if a future model needs wider features.
    static let maxEmbeddingFloats = 1 << 20

    private static let needle2 = NativeRuntime()
    private static let needle3 = NativeRuntime()

    static func shared(for generation: Int) -> NativeRuntime {
        generation == 2 ? needle2 : needle3
    }

    private var api: NativeAPI?
    private var libraryPath: String?
    private var activeID: UUID?
    private var activeWeights: String?
    private var weightsBlob: NSData?
    private var calibratedWeights = false
    private var speechWeights: String?
    private var speechBlob: NSData?
    private var initializationStorage: [NSData] = []
    private var closedSessions: Set<UUID> = []
    /// The open live transcription, which the engine holds one of.
    private var openStream: StreamSession?
    /// Streams ended by `closeSpeech` that have not yet observed the stop.
    private var endedStreams: Set<UUID> = []

    init(api: NativeAPI? = nil) {
        self.api = api
    }

    func initialize(_ session: Session, library: URL) throws {
        try ensureLibrary(library, generation: session.generation)
        try bind(session)
    }

    private func ensureLibrary(_ library: URL, generation: Int) throws {
        try Task.checkCancellation()
        let path = library.standardizedFileURL.path
        if let libraryPath, libraryPath != path {
            throw CactusError.native("engine already loaded from \(libraryPath)")
        }
        if api == nil {
            api = try NativeAPI.open(path, generation: generation)
        }
        libraryPath = path
    }

    func complete(_ session: Session, text: String, tokens: Int32, reset: Bool = false) throws -> Response {
        try Task.checkCancellation()
        let api = try bind(session)
        if reset {
            api.reset()
        }
        var buffer = [CChar](repeating: 0, count: session.bufferSize)
        let code = buffer.withUnsafeMutableBufferPointer { api.complete(text, tokens, $0) }
        // Cancellation cannot interrupt the native ABI; observe it when inference returns.
        try Task.checkCancellation()
        return try decodeResponse(session, api: api, code: code, buffer: buffer)
    }

    private func decodeResponse(_ session: Session, api: NativeAPI, code: Int32, buffer: [CChar]) throws -> Response {
        var response = try JSONDecoder().decode(Response.self, from: api.output("complete", code: code, buffer: buffer))
        guard !response.type.isEmpty else { throw CactusError.native("response type is empty") }
        if session.tuned, !calibratedWeights {
            response.confidence = nil
        }
        return response
    }

    func reset(_ session: Session) throws {
        try Task.checkCancellation()
        try bind(session).reset()
    }

    /// Releases a text session; later calls throw `CactusError.closed`. The next
    /// agent reinitializes the engine.
    func close(_ session: Session) {
        closedSessions.insert(session.id)
        if activeID == session.id {
            activeID = nil
        }
    }

    /// Ends the session's open stream and releases the session; later calls throw `CactusError.closed`.
    func closeSpeech(_ session: SpeechSession) {
        if let openStream, openStream.speech.id == session.id {
            endStream(openStream)
            endedStreams.insert(openStream.id)
        }
        closedSessions.insert(session.id)
    }

    func embed(_ session: Session, text: String) throws -> [Float] {
        try Task.checkCancellation()
        guard session.generation == 3 else { throw CactusError.embeddingUnsupported("embeddings require Needle 3") }
        try validateCString(text, name: "input")
        let api = try bind(session)
        // Only the Needle 2 engine lacks these, and its runtime never serves Needle 3.
        guard let embed = api.cactus?.embed else { throw Self.cactusRequired }
        let size = embed(text, UnsafeMutableBufferPointer(start: nil, count: 0))
        guard size >= 0 else { throw api.failure("embed size", code: size) }
        guard
            size > 0,
            size <= Self.maxEmbeddingFloats else { throw CactusError.native("invalid embedding size \(size)") }
        try Task.checkCancellation()
        var output = [Float](repeating: 0, count: Int(size))
        let code = output.withUnsafeMutableBufferPointer { embed(text, $0) }
        try Task.checkCancellation()
        guard code >= 0 else { throw api.failure("embed", code: code) }
        guard code == size else { throw CactusError.native("embedding length \(code), want \(size)") }
        return output
    }

    func initializeSpeech(_ session: SpeechSession, library: URL) throws {
        try ensureLibrary(library, generation: 3)
        try bindSpeech(session)
    }

    /// A loaded library without the cactus_* functions; only the Needle 2 engine lacks them.
    private static let cactusRequired = CactusError.unsupportedABI("Cactus engine is required")

    @discardableResult
    private func bindSpeech(_ session: SpeechSession) throws -> (NativeAPI, CactusFunctions) {
        guard let api else { throw CactusError.native("engine is not loaded") }
        guard let cactus = api.cactus else { throw Self.cactusRequired }
        guard !closedSessions.contains(session.id) else { throw CactusError.closed }
        if speechWeights != session.weightsPath {
            // Switching speech weights would discard the open stream.
            guard openStream == nil else { throw CactusError.streamActive }
            let data = try Data(contentsOf: URL(fileURLWithPath: session.weightsPath))
            guard WeightMetadata(data)?.kind == .speech else {
                throw CactusError.invalidInput("weights are not a recognized speech model")
            }
            let blob = NSData(data: data)
            let code = api.load(blob.bytes, UInt64(blob.length))
            guard code >= 0 else {
                speechWeights = nil
                throw api.failure("load speech weights", code: code)
            }
            speechBlob = blob
            speechWeights = session.weightsPath
        }
        return (api, cactus)
    }

    func transcribe(_ session: SpeechSession, pcm: [Float], options: AudioOptions) throws -> Transcript {
        try Task.checkCancellation()
        guard openStream == nil else { throw CactusError.streamActive }
        let (api, cactus) = try bindSpeech(session)
        let transcribe = cactus.transcribe
        var buffer = [CChar](repeating: 0, count: session.outputCapacity(samples: pcm.count))
        let samples = pcm.isEmpty ? [Float(0)] : pcm
        let code = samples.withUnsafeBufferPointer { samples in
            // The audio ABI requires nonnull PCM even for an empty clip.
            let clip = UnsafeBufferPointer(start: samples.baseAddress, count: pcm.count)
            return buffer.withUnsafeMutableBufferPointer { transcribe(clip, options, $0) }
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(Transcript.self, from: api.output("transcribe", code: code, buffer: buffer))
    }

    func completeSpeech(
        _ session: SpeechSession, text: Session, pcm: [Float], options: AudioOptions, tokens: Int32
    ) throws -> Response {
        try Task.checkCancellation()
        guard openStream == nil else { throw CactusError.streamActive }
        let (api, cactus) = try bindSpeech(session)
        try bind(text)
        let (complete, setAudio) = (cactus.completeAudio, cactus.setAudio)
        if text.stateless {
            api.reset()
        }
        setAudio(options)
        defer { setAudio(AudioOptions()) }
        var buffer = [CChar](repeating: 0, count: text.bufferSize)
        let samples = pcm.isEmpty ? [Float(0)] : pcm
        let code = samples.withUnsafeBufferPointer { samples in
            let clip = UnsafeBufferPointer(start: samples.baseAddress, count: pcm.count)
            return buffer.withUnsafeMutableBufferPointer { complete(clip, tokens, $0) }
        }
        try Task.checkCancellation()
        // Decode/copy the native error before deferred audio-option cleanup can replace it.
        return try decodeResponse(text, api: api, code: code, buffer: buffer)
    }

    func streamProcess(_ stream: StreamSession, pcm: [Float]) throws -> StreamTranscript {
        try Task.checkCancellation()
        let (api, cactus) = try bindStream(stream)
        let process = cactus.streamProcess
        var buffer = [CChar](repeating: 0, count: stream.speech.outputCapacity(samples: pcm.count))
        let samples = pcm.isEmpty ? [Float(0)] : pcm
        let code = samples.withUnsafeBufferPointer { samples in
            let chunk = UnsafeBufferPointer(start: samples.baseAddress, count: pcm.count)
            return buffer.withUnsafeMutableBufferPointer { process(chunk, stream.options, $0) }
        }
        openStream = stream
        let step: StreamTranscript
        do {
            step = try Self.decodeStep(api, "stream", code: code, buffer: buffer)
        } catch {
            // The engine's stream state is unknown after a failure; end it so
            // other speech calls are not blocked.
            endStream(stream)
            throw StreamFailure(error)
        }
        try Task.checkCancellation()
        return step
    }

    func streamStop(_ stream: StreamSession) throws -> StreamTranscript {
        try Task.checkCancellation()
        let (api, cactus) = try bindStream(stream)
        let stop = cactus.streamStop
        var buffer = [CChar](repeating: 0, count: stream.speech.bufferSize)
        let code = buffer.withUnsafeMutableBufferPointer { stop($0) }
        openStream = nil
        do {
            return try Self.decodeStep(api, "stream stop", code: code, buffer: buffer)
        } catch {
            throw StreamFailure(error)
        }
    }

    /// Checks that this stream may use the engine.
    private func bindStream(_ stream: StreamSession) throws -> (NativeAPI, CactusFunctions) {
        if endedStreams.remove(stream.id) != nil {
            throw StreamFailure(TranscriptionStream.stoppedError)
        }
        if let openStream, openStream.id != stream.id {
            throw CactusError.streamActive
        }
        return try bindSpeech(stream.speech)
    }

    /// Stops the engine's stream without reporting its tail.
    private func endStream(_ stream: StreamSession) {
        guard openStream?.id == stream.id else { return }
        if let stop = api?.cactus?.streamStop {
            var buffer = [CChar](repeating: 0, count: stream.speech.bufferSize)
            _ = buffer.withUnsafeMutableBufferPointer { stop($0) }
        }
        openStream = nil
    }

    private static func decodeStep(
        _ api: NativeAPI, _ operation: String, code: Int32, buffer: [CChar]
    ) throws -> StreamTranscript {
        try JSONDecoder().decode(StreamTranscript.self, from: api.output(operation, code: code, buffer: buffer))
    }

    @discardableResult
    private func bind(_ session: Session) throws -> NativeAPI {
        guard let api else { throw CactusError.native("engine is not loaded") }
        guard !closedSessions.contains(session.id) else { throw CactusError.closed }
        if activeID == session.id {
            return api
        }
        if session.weightsPath == nil, activeWeights != nil {
            throw CactusError.native("tuned weights cannot be unloaded; use a separate process for the base model")
        }
        if let path = session.weightsPath, path != activeWeights {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let generation = try Self.weightsGeneration(data)
            guard generation == session.generation else {
                throw CactusError
                    .invalidInput("weights generation changed: got \(generation), want \(session.generation)")
            }
            let metadata = WeightMetadata(data)
            guard generation != 3 || metadata?.kind == .text else {
                throw CactusError.invalidInput("weights are not a recognized text model")
            }
            let blob = NSData(data: data)
            let code = api.load(blob.bytes, UInt64(blob.length))
            guard code >= 0 else { throw api.failure("load weights", code: code) }
            // NSData supplies a stable allocation for engines that retain the weight pointer.
            weightsBlob = blob
            activeWeights = path
            calibratedWeights = generation == 3 && metadata?.hasConfidenceHead == true
        }
        activeID = nil
        let storage = ([session.system, session.tools] + [session.toolIndexPath].compactMap(\.self))
            .map { NSData(data: Data($0.utf8) + [0]) }
        // Keep C strings alive for engines that retain init arguments, including failed rebinds.
        initializationStorage += storage
        let code = api.initialize(
            storage[0].bytes.assumingMemoryBound(to: CChar.self),
            storage[1].bytes.assumingMemoryBound(to: CChar.self),
            storage.count == 3 ? storage[2].bytes.assumingMemoryBound(to: CChar.self) : nil
        )
        guard code >= 0 else { throw api.failure("initialize", code: code) }
        initializationStorage = storage
        activeID = session.id
        return api
    }

    static func weightsGeneration(_ data: Data) throws -> Int {
        guard data.count >= 4 else { throw CactusError.invalidInput("weights header is truncated") }
        let tag = data.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        switch tag {
        case Cact.needle2Tag: return 2
        case Cact.needle3Tag: return 3
        default: throw CactusError.invalidInput("unknown weights header 0x\(String(tag, radix: 16))")
        }
    }
}
