import Foundation
#if canImport(onnxruntime)
import onnxruntime

/// Kokoro-82M run by ONNX Runtime on the CPU (docs/read-aloud.md: the CPU is
/// allowed in the background, and ONNX Runtime has its own kernels, not the
/// system's BNNS, which Core ML's Kokoro crashes in on current iOS).
///
/// One sentence (or piece of one) at a time: its tokens, the voice's style
/// for that length, and a speed, in; 24 kHz mono samples out. Calls are not
/// safe from two threads at once; `KokoroSpeechEngine` makes them from one
/// queue.
final class KokoroModel {
    static let sampleRate = 24_000.0

    enum ModelError: Error, CustomStringConvertible {
        case ort(String)
        var description: String { if case .ort(let m) = self { return m }; return "" }
    }

    /// Always true, except in a Debug test of the telemetry check
    /// (`PLATEN_ORT_TELEMETRY_TEST`).
    static var noTelemetry: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PLATEN_ORT_TELEMETRY_TEST"]?.isEmpty ?? true
        #else
        return true
        #endif
    }

    private let api: OrtApi
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private var memory: OpaquePointer?

    /// - Parameter threads: CPU threads for one synthesis (2 suits a phone:
    ///   fast enough, and leaves the other cores to the rest of the system).
    init(model: URL, threads: Int = 2) throws {
        // No telemetry (spec). ONNX Runtime's Apple build carries Microsoft's
        // telemetry client (1DS, to mobile.events.data.microsoft.com), on by
        // default. It is switched off before ONNX Runtime does anything: by
        // the environment setting it reads when its environment is made, and
        // again by its API once that exists (docs/read-aloud.md, "ONNX
        // Runtime's telemetry"). `noTelemetry` lets a Debug test turn this
        // off, to show that the check really sees the traffic.
        if Self.noTelemetry { setenv("ORT_DISABLE_TELEMETRY", "1", 1) }
        guard let base = OrtGetApiBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw ModelError.ort("ONNX Runtime is not available")
        }
        self.api = api.pointee
        try check(self.api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "platen", &env))
        if Self.noTelemetry { try check(self.api.DisableTelemetryEvents(env)) }
        var options: OpaquePointer?
        try check(self.api.CreateSessionOptions(&options))
        defer { self.api.ReleaseSessionOptions(options) }
        try check(self.api.SetIntraOpNumThreads(options, Int32(threads)))
        try check(self.api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        try model.path.withCString { path in
            try check(self.api.CreateSession(env, path, options, &session))
        }
        try check(self.api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
    }

    deinit {
        if let memory { api.ReleaseMemoryInfo(memory) }
        if let session { api.ReleaseSession(session) }
        if let env { api.ReleaseEnv(env) }
    }

    /// Speech for one piece: `tokens` (with the 0 at each end), the voice's
    /// 256 style values for this length, and `speed` (1 normal).
    func synthesize(tokens: [Int64], style: [Float], speed: Float) throws -> [Float] {
        var ids = tokens
        var styleValues = style
        var speedValue = speed
        var idShape: [Int64] = [1, Int64(ids.count)]
        var styleShape: [Int64] = [1, 256]
        var speedShape: [Int64] = [1]
        var inputs: [OpaquePointer?] = [nil, nil, nil]
        defer { for value in inputs where value != nil { api.ReleaseValue(value) } }

        try ids.withUnsafeMutableBytes { buffer in
            try check(api.CreateTensorWithDataAsOrtValue(memory, buffer.baseAddress, buffer.count, &idShape, 2,
                                                         ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[0]))
        }
        try styleValues.withUnsafeMutableBytes { buffer in
            try check(api.CreateTensorWithDataAsOrtValue(memory, buffer.baseAddress, buffer.count, &styleShape, 2,
                                                         ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inputs[1]))
        }
        try withUnsafeMutableBytes(of: &speedValue) { buffer in
            try check(api.CreateTensorWithDataAsOrtValue(memory, buffer.baseAddress, buffer.count, &speedShape, 1,
                                                         ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inputs[2]))
        }

        let inputNames = ["input_ids", "style", "speed"]
        let outputNames = ["waveform"]
        var output: OpaquePointer?
        try withCStrings(inputNames) { inNames in
            try withCStrings(outputNames) { outNames in
                try inputs.withUnsafeBufferPointer { values in
                    let constValues = UnsafeRawPointer(values.baseAddress!).assumingMemoryBound(to: OpaquePointer?.self)
                    try check(api.Run(session, nil, inNames, constValues, 3, outNames, 1, &output))
                }
            }
        }
        defer { api.ReleaseValue(output) }

        var info: OpaquePointer?
        try check(api.GetTensorTypeAndShape(output, &info))
        defer { api.ReleaseTensorTypeAndShapeInfo(info) }
        var count = 0
        try check(api.GetTensorShapeElementCount(info, &count))
        var data: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(output, &data))
        guard let data else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }

    private func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "ONNX Runtime error"
        api.ReleaseStatus(status)
        throw ModelError.ort(message)
    }

    private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> R) rethrows -> R {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        let constPointers = pointers.map { UnsafePointer($0) }
        return try constPointers.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }
}
#endif

/// A Kokoro voice: 510 rows of 256 style values, the row chosen by the
/// length of what is said (`style(forTokens:)`). The .bin files in the
/// voice pack's `voices` folder.
struct KokoroVoicePack {
    let name: String
    private let rows: [Float]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), data.count == 510 * 256 * 4 else { return nil }
        name = url.deletingPathExtension().lastPathComponent
        rows = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// The style for a piece of `count` tokens (the 0s at the ends not
    /// counted, as Kokoro's own pipeline does).
    func style(forTokens count: Int) -> [Float] {
        let row = min(max(count - 2, 0), 509)
        return Array(rows[(row * 256)..<((row + 1) * 256)])
    }

    /// Voices are British ("bf_", "bm_") or American ("af_", "am_").
    var isBritish: Bool { name.hasPrefix("b") }
}
