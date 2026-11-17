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
    typealias SetThreads = @convention(c) (Int32) -> Void
    typealias Reset = @convention(c) () -> Void
    typealias Load = @convention(c) (UnsafeRawPointer?, UInt64) -> Int32
    typealias LastError = @convention(c) () -> UnsafePointer<CChar>?
    typealias Embed = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<Float>?, Int32
    ) -> Int32
    /// Returns a token count, not the byte length of the NUL-terminated output.
    typealias Describe = @convention(c) (
        UnsafePointer<UInt8>?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafeMutablePointer<CChar>?, Int32
    ) -> Int32
    typealias Models = @convention(c) () -> Int32

    let initialize: @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>?) -> Int32
    let complete: @Sendable (String, Int32, UnsafeMutableBufferPointer<CChar>) -> Int32
    let reset: @Sendable () -> Void
    let load: @Sendable (UnsafeRawPointer, UInt64) -> Int32

    var lastError: (@Sendable () -> String?)?
    /// The functions only the Cactus engine exports; nil for the Needle 2 engine.
    var cactus: CactusFunctions?

    /// The Needle 2 engine's needle_* ABI: it embeds its model and completes with four arguments.
    static let needle2Symbols = ["init", "complete", "reset", "load"]

    /// The cactus_* ABI that the Cactus engine exports in full.
    static let cactusSymbols = [
        "load", "models", "last_error", "init", "complete", "set_audio", "set_threads", "reset",
        "embed", "transcribe", "stream_transcribe_process", "stream_transcribe_stop", "describe",
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
    /// for the Cactus engine that runs Needle 3, Whistle and Mirage. A library
    /// missing any function of that ABI is rejected.
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
