@testable import Cactus
import Foundation
import Testing

private extension Error {
    var cactusCase: String? {
        switch self as? CactusError {
        case .invalidInput: "invalidInput"
        case .unsupportedGeneration: "unsupportedGeneration"
        case .unsupportedABI: "unsupportedABI"
        case .embeddingUnsupported: "embeddingUnsupported"
        case .nativeFailure: "nativeFailure"
        case .native: "native"
        case .streamActive: "streamActive"
        case .closed: "closed"
        case .download: "download"
        case .validation: "validation"
        case nil: nil
        }
    }
}

@Test
func typedErrorsAreMatchable() async throws {
    #expect { try Session(Configuration(generation: 4)) } throws: { $0.cactusCase == "unsupportedGeneration" }
    #expect { try EngineRelease(1) } throws: { $0.cactusCase == "unsupportedGeneration" }
    var symbols = nativeSymbols(generation: 3)
    symbols["cactus_load"] = nil
    #expect { try NativeAPI.bind(generation: 3) { symbols[$0] } } throws: { error in
        guard case .unsupportedABI("Cactus engine is missing cactus_load") = error as? CactusError else {
            return false
        }
        return error.localizedDescription == "cactus: unsupported native ABI: Cactus engine is missing cactus_load"
    }

    let flagged = #"{"type":"call","function_calls":[{"name":"x","arguments":{}}],"validation":{"ungrounded":["x.a"]}}"#
    let agent = try await FakeNative([flagged]).agent()
    await #expect { try await agent.run("hello") } throws: { error in
        guard case let .validation(response) = error as? CactusError else { return false }
        return response.validation?.ungrounded == ["x.a"]
    }
    await #expect { try await agent.embed("hello") } throws: { $0.cactusCase == "embeddingUnsupported" }

    let broken = try await FakeNative(["native failure"], completeCode: -3).agent()
    await #expect { try await broken.complete("hello") } throws: { error in
        guard case .nativeFailure(operation: "complete", code: -3, detail: "native failure") = error as? CactusError
        else { return false }
        return error.localizedDescription == "cactus: complete failed with code -3: native failure"
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let speech = directory.appendingPathComponent("speech.cact")
    try testWeights(speech: true).write(to: speech)
    // Whistle runs only on the Cactus engine; the Needle 2 engine has no speech functions.
    let needle2 = WhistleConfiguration(weightsPath: speech.path, libraryPath: "/test/libneedle.dylib")
    await #expect {
        try await Whistle(configuration: needle2, runtime: NativeRuntime(api: FakeNative().api))
    } throws: { $0.localizedDescription == "cactus: unsupported native ABI: Cactus engine is required" }
}
