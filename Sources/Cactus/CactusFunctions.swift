import Foundation

/// The Cactus engine functions beyond the text ABI it shares with Needle 2:
/// embeddings, speech, live transcription and vision.
struct CactusFunctions: Sendable {
    typealias StreamProcessCall = @Sendable (
        UnsafeBufferPointer<Float>,
        AudioOptions,
        UnsafeMutableBufferPointer<CChar>
    ) -> Int32

    /// The cactus_models bit of a loaded vision model; text is 1 and speech 2.
    static let visionModel: Int32 = 4

    var embed: @Sendable (String, UnsafeMutableBufferPointer<Float>) -> Int32
    var transcribe: @Sendable (UnsafeBufferPointer<Float>, AudioOptions, UnsafeMutableBufferPointer<CChar>) -> Int32
    var setAudio: @Sendable (AudioOptions) -> Void
    var completeAudio: @Sendable (UnsafeBufferPointer<Float>, Int32, UnsafeMutableBufferPointer<CChar>) -> Int32
    var streamProcess: StreamProcessCall
    var streamStop: @Sendable (UnsafeMutableBufferPointer<CChar>) -> Int32
    var describe: @Sendable (RGBImage, VisionRequest, UnsafeMutableBufferPointer<CChar>) -> Int32
    /// The bitmask of loaded model kinds.
    var models: @Sendable () -> Int32
}

extension CactusFunctions {
    init(_ function: NativeAPI.Symbols) throws {
        let embed = try function("embed", as: NativeAPI.Embed.self)
        let complete = try function("complete", as: NativeAPI.CompleteWithAudio.self)
        let transcribe = try function("transcribe", as: NativeAPI.Transcribe.self)
        let setAudio = try function("set_audio", as: NativeAPI.SetAudio.self)
        let streamProcess = try function("stream_transcribe_process", as: NativeAPI.StreamProcess.self)
        let streamStop = try function("stream_transcribe_stop", as: NativeAPI.StreamStop.self)
        let describe = try function("describe", as: NativeAPI.Describe.self)
        let models = try function("models", as: NativeAPI.Models.self)
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
            streamStop: { output in streamStop(output.baseAddress, Int32(output.count)) },
            describe: { image, request, output in
                // The pixels reach the engine without a copy.
                image.pixels.withUnsafeBufferPointer { rgb in
                    request.withCStrings { options, language, keywords in
                        describe(
                            rgb.baseAddress,
                            Int32(image.width),
                            Int32(image.height),
                            options,
                            language,
                            keywords,
                            output.baseAddress,
                            Int32(output.count)
                        )
                    }
                }
            },
            models: { models() }
        )
    }
}
