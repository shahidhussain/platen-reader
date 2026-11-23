import Accelerate
import Foundation

// Kokoro-82M (hexgrad, Apache-2.0) in plain Swift on Accelerate: no machine
// learning runtime, so nothing in the app but our own code and Apple's
// maths library (docs/read-aloud.md, "Running the model"). A port of
// hexgrad/kokoro's PyTorch model (model.py, modules.py, istftnet.py), which
// builds on StyleTTS 2 and iSTFTNet (both MIT), for one sentence at a time.
//
// This is its own module in the PlatenCore package, compiled with
// optimisation even in Debug builds (Package.swift): unoptimised, its loops
// run some sixty times slower, too slow to read aloud while testing.
//
// Tensors are plain [Float] arrays in row-major order. A 1-D signal with
// several channels is (channels × time); text is (time × features).

// MARK: - Weights

/// The model's weights, read from the voice pack (`kokoro-weights.bin`, with
/// its index `kokoro-weights.json`, made by scripts/make-kokoro-pack.py).
///
/// The file is memory-mapped, not read: iOS pages it in as it is used and
/// can drop it again under memory pressure, so the 82 MB of weights never
/// count as the app's own memory. Large weights are stored as 8-bit integers
/// with one scale per row (an output channel), and turned back into floats
/// only while a layer is being computed. Weight normalisation (g · v / ‖v‖)
/// is already folded in by the pack script.
final class KokoroWeights {
    private struct Entry {
        let shape: [Int]
        let offset: Int
        /// Int8 rows with a Float32 scale each (at `scales`), or Float32.
        let quantised: Bool
        let scales: Int
    }

    private let data: Data
    private let index: [String: Entry]

    public enum LoadError: Error { case unreadable(String) }

    init(bin: URL, json: URL) throws {
        data = try Data(contentsOf: bin, options: .alwaysMapped)
        guard let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: [String: Any]] else {
            throw LoadError.unreadable(json.lastPathComponent)
        }
        var index: [String: Entry] = [:]
        for (name, value) in raw {
            guard let shape = value["shape"] as? [Int], let offset = value["offset"] as? Int,
                  let type = value["type"] as? String else { throw LoadError.unreadable(name) }
            index[name] = Entry(shape: shape, offset: offset, quantised: type == "q8", scales: value["scales"] as? Int ?? 0)
        }
        self.index = index
    }

    func shape(_ name: String) -> [Int] {
        guard let entry = index[name] else { fatalError("Kokoro: no weight \(name)") }
        return entry.shape
    }

    /// A weight as floats (a fresh copy, freed when the caller is done).
    func get(_ name: String) -> [Float] {
        guard let entry = index[name] else { fatalError("Kokoro: no weight \(name)") }
        let count = entry.shape.reduce(1, *)
        return data.withUnsafeBytes { raw -> [Float] in
            let base = raw.baseAddress!
            if !entry.quantised {
                let floats = (base + entry.offset).assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: floats, count: count))
            }
            let rows = entry.shape[0], per = count / rows
            let bytes = (base + entry.offset).assumingMemoryBound(to: Int8.self)
            let scales = (base + entry.scales).assumingMemoryBound(to: Float.self)
            return [Float](unsafeUninitializedCapacity: count) { out, initialised in
                vDSP_vflt8(bytes, 1, out.baseAddress!, 1, vDSP_Length(count))
                for r in 0..<rows {
                    var scale = scales[r]
                    vDSP_vsmul(out.baseAddress! + r * per, 1, &scale, out.baseAddress! + r * per, 1, vDSP_Length(per))
                }
                initialised = count
            }
        }
    }
}

// MARK: - The model

/// Kokoro-82M: one piece of a sentence (its tokens, with the 0 at each end),
/// a voice's 256 style values for that length, and a speed, in; 24 kHz mono
/// samples, and how many frames each token lasts, out. Not safe to call from
/// two threads at once (`KokoroSpeechEngine` calls it from one queue).
public final class KokoroModel {
    public static let sampleRate = 24_000.0
    /// Audio samples per duration frame (the generator upsamples 2 × 10 × 6
    /// × 5).
    public static let samplesPerFrame = 600

    private let W: KokoroWeights

    /// `pack`: the voice pack's folder.
    public init(pack: URL) throws {
        W = try KokoroWeights(bin: pack.appendingPathComponent("kokoro-weights.bin"),
                              json: pack.appendingPathComponent("kokoro-weights.json"))
    }

    public func synthesize(tokens: [Int64], style: [Float], speed: Float) -> (samples: [Float], durations: [Int]) {
        let ids = tokens.map(Int.init)
        let t = ids.count
        // The voice's style: the first half shapes the sound (decoder), the
        // second the rhythm and pitch (predictor).
        let sDec = Array(style[0..<128]), sPred = Array(style[128..<256])

        // 1. The phonemes in context (Albert), then the duration encoder:
        // three LSTMs, each followed by a layer norm the style adjusts, with
        // the style appended to every step.
        let bert = albert(ids)
        let dEn = linear(bert, rows: t, W.get("bert_encoder.weight"), W.get("bert_encoder.bias"), out: 512)
        var d = [Float](repeating: 0, count: t * 640)
        func appendStyle(_ x: [Float]) {
            for i in 0..<t {
                for j in 0..<512 { d[i * 640 + j] = x[i * 512 + j] }
                for j in 0..<128 { d[i * 640 + 512 + j] = sPred[j] }
            }
        }
        appendStyle(dEn)
        let pe = "predictor.text_encoder.lstms."
        for layer in 0..<3 {
            var x = biLSTM(d, steps: t, "\(pe)\(2 * layer)")
            let h = linear(sPred, rows: 1, W.get("\(pe)\(2 * layer + 1).fc.weight"), W.get("\(pe)\(2 * layer + 1).fc.bias"), out: 1024)
            layerNorm(&x, rows: t, n: 512, nil, nil, eps: 1e-5)
            for i in 0..<t { for j in 0..<512 { x[i * 512 + j] = (1 + h[j]) * x[i * 512 + j] + h[512 + j] } }
            appendStyle(x)
        }

        // 2. How long each phoneme lasts, in frames of 600 samples.
        let lstm = biLSTM(d, steps: t, "predictor.lstm")
        let logits = linear(lstm, rows: t, W.get("predictor.duration_proj.linear_layer.weight"),
                            W.get("predictor.duration_proj.linear_layer.bias"), out: 50)
        var durations = [Int](repeating: 1, count: t)
        for i in 0..<t {
            var sum: Float = 0
            for j in 0..<50 { sum += sigmoid(logits[i * 50 + j]) }
            durations[i] = max(1, Int((sum / speed).rounded(.toNearestOrEven)))
        }
        let frames = durations.reduce(0, +)
        var frameToken = [Int]()
        frameToken.reserveCapacity(frames)
        for i in 0..<t { frameToken += repeatElement(i, count: durations[i]) }

        // 3. Pitch (F0) and energy (N) for every half-frame.
        var en = [Float](repeating: 0, count: frames * 640)
        for f in 0..<frames { let i = frameToken[f]; for j in 0..<640 { en[f * 640 + j] = d[i * 640 + j] } }
        let shared = transpose(biLSTM(en, steps: frames, "predictor.shared"), rows: frames, cols: 512)
        en = []
        func curve(_ name: String) -> [Float] {
            var (x, xt) = adainResBlk(shared, cin: 512, t: frames, cout: 512, style: sPred, upsample: false, "predictor.\(name).0")
            (x, xt) = adainResBlk(x, cin: 512, t: xt, cout: 256, style: sPred, upsample: true, "predictor.\(name).1")
            (x, xt) = adainResBlk(x, cin: 256, t: xt, cout: 256, style: sPred, upsample: false, "predictor.\(name).2")
            return conv1d(x, cin: 256, t: xt, W.get("predictor.\(name)_proj.weight"), W.get("predictor.\(name)_proj.bias"), cout: 1, k: 1).y
        }
        let f0 = curve("F0"), energy = curve("N")

        // 4. The text encoder (embeddings, three convolutions, an LSTM),
        // stretched to frames.
        let embedding = W.get("text_encoder.embedding.weight")
        var te = [Float](repeating: 0, count: 512 * t)
        for i in 0..<t { for j in 0..<512 { te[j * t + i] = embedding[ids[i] * 512 + j] } }
        for layer in 0..<3 {
            let p = "text_encoder.cnn.\(layer)"
            te = conv1d(te, cin: 512, t: t, W.get(p + ".0.weight"), W.get(p + ".0.bias"), cout: 512, k: 5, padding: 2).y
            var rows = transpose(te, rows: 512, cols: t)
            layerNorm(&rows, rows: t, n: 512, W.get(p + ".1.gamma"), W.get(p + ".1.beta"), eps: 1e-5)
            leakyRelu(&rows, 0.2)
            te = transpose(rows, rows: t, cols: 512)
        }
        let textEncoded = biLSTM(transpose(te, rows: 512, cols: t), steps: t, "text_encoder.lstm")
        var asr = [Float](repeating: 0, count: 512 * frames)
        for f in 0..<frames { let i = frameToken[f]; for j in 0..<512 { asr[j * frames + f] = textEncoded[i * 512 + j] } }

        // 5. The decoder, then the generator makes the sound.
        let f0Down = conv1d(f0, cin: 1, t: 2 * frames, W.get("decoder.F0_conv.weight"), W.get("decoder.F0_conv.bias"),
                            cout: 1, k: 3, stride: 2, padding: 1).y
        let nDown = conv1d(energy, cin: 1, t: 2 * frames, W.get("decoder.N_conv.weight"), W.get("decoder.N_conv.bias"),
                           cout: 1, k: 3, stride: 2, padding: 1).y
        var (x, xt) = adainResBlk(asr + f0Down + nDown, cin: 514, t: frames, cout: 1024, style: sDec, upsample: false, "decoder.encode")
        let asrRes = conv1d(asr, cin: 512, t: frames, W.get("decoder.asr_res.0.weight"), W.get("decoder.asr_res.0.bias"), cout: 64, k: 1).y
        asr = []
        for block in 0..<4 {
            (x, xt) = adainResBlk(x + asrRes + f0Down + nDown, cin: 1090, t: frames, cout: block == 3 ? 512 : 1024,
                                  style: sDec, upsample: block == 3, "decoder.decode.\(block)")
        }
        let samples = generator(x, t: xt, style: sDec, f0: f0)
        return (samples, durations)
    }

    // MARK: Albert (the phoneme encoder)

    private func albert(_ ids: [Int]) -> [Float] {
        let t = ids.count, e = 128, width = 768, heads = 12, headWidth = 64
        let p = "bert."
        let word = W.get(p + "embeddings.word_embeddings.weight"), position = W.get(p + "embeddings.position_embeddings.weight")
        let type = W.get(p + "embeddings.token_type_embeddings.weight")
        var x = [Float](repeating: 0, count: t * e)
        for i in 0..<t { for j in 0..<e { x[i * e + j] = word[ids[i] * e + j] + position[i * e + j] + type[j] } }
        layerNorm(&x, rows: t, n: e, W.get(p + "embeddings.LayerNorm.weight"), W.get(p + "embeddings.LayerNorm.bias"), eps: 1e-12)
        var hidden = linear(x, rows: t, W.get(p + "encoder.embedding_hidden_mapping_in.weight"),
                            W.get(p + "encoder.embedding_hidden_mapping_in.bias"), out: width)
        // Albert has one layer, applied twelve times.
        let l = p + "encoder.albert_layer_groups.0.albert_layers.0."
        let wq = W.get(l + "attention.query.weight"), bq = W.get(l + "attention.query.bias")
        let wk = W.get(l + "attention.key.weight"), bk = W.get(l + "attention.key.bias")
        let wv = W.get(l + "attention.value.weight"), bv = W.get(l + "attention.value.bias")
        let wd = W.get(l + "attention.dense.weight"), bd = W.get(l + "attention.dense.bias")
        let normA = (W.get(l + "attention.LayerNorm.weight"), W.get(l + "attention.LayerNorm.bias"))
        let wf = W.get(l + "ffn.weight"), bf = W.get(l + "ffn.bias")
        let wo = W.get(l + "ffn_output.weight"), bo = W.get(l + "ffn_output.bias")
        let normF = (W.get(l + "full_layer_layer_norm.weight"), W.get(l + "full_layer_layer_norm.bias"))
        let scale = 1 / Float(headWidth).squareRoot()
        var scores = [Float](repeating: 0, count: t)
        for _ in 0..<12 {
            let q = linear(hidden, rows: t, wq, bq, out: width), k = linear(hidden, rows: t, wk, bk, out: width)
            let v = linear(hidden, rows: t, wv, bv, out: width)
            var context = [Float](repeating: 0, count: t * width)
            for h in 0..<heads {
                let o = h * headWidth
                for i in 0..<t {
                    var top = -Float.infinity
                    for j in 0..<t {
                        var s: Float = 0
                        for c in 0..<headWidth { s += q[i * width + o + c] * k[j * width + o + c] }
                        scores[j] = s * scale
                        top = max(top, scores[j])
                    }
                    var sum: Float = 0
                    for j in 0..<t { scores[j] = exp(scores[j] - top); sum += scores[j] }
                    for c in 0..<headWidth {
                        var acc: Float = 0
                        for j in 0..<t { acc += scores[j] * v[j * width + o + c] }
                        context[i * width + o + c] = acc / sum
                    }
                }
            }
            var attended = linear(context, rows: t, wd, bd, out: width)
            add(&attended, hidden)
            layerNorm(&attended, rows: t, n: width, normA.0, normA.1, eps: 1e-12)
            var ff = linear(attended, rows: t, wf, bf, out: 2048)
            for i in ff.indices { // GELU, tanh approximation ("gelu_new")
                let v = ff[i]
                ff[i] = 0.5 * v * (1 + tanh(0.7978845608 * (v + 0.044715 * v * v * v)))
            }
            var out = linear(ff, rows: t, wo, bo, out: width)
            add(&out, attended)
            layerNorm(&out, rows: t, n: width, normF.0, normF.1, eps: 1e-12)
            hidden = out
        }
        return hidden
    }

    // MARK: LSTM

    /// A one-layer bidirectional LSTM: x (steps × in) → (steps × 2·hidden),
    /// the forward and backward passes side by side. PyTorch's gate order:
    /// input, forget, cell, output.
    private func biLSTM(_ x: [Float], steps: Int, _ p: String) -> [Float] {
        let hidden = W.shape(p + ".weight_hh_l0")[1], gates = 4 * hidden
        var out = [Float](repeating: 0, count: steps * 2 * hidden)
        for (direction, suffix) in [(0, ""), (1, "_reverse")] {
            let bias = zip(W.get(p + ".bias_ih_l0" + suffix), W.get(p + ".bias_hh_l0" + suffix)).map(+)
            // Every step's input part at once.
            let fromInput = linear(x, rows: steps, W.get(p + ".weight_ih_l0" + suffix), bias, out: gates)
            let recurrent = W.get(p + ".weight_hh_l0" + suffix)
            var h = [Float](repeating: 0, count: hidden), c = h
            var g = [Float](repeating: 0, count: gates)
            for s in 0..<steps {
                let step = direction == 0 ? s : steps - 1 - s
                for i in 0..<gates { g[i] = fromInput[step * gates + i] }
                recurrent.withUnsafeBufferPointer { w in h.withUnsafeBufferPointer { hp in g.withUnsafeMutableBufferPointer { gp in
                    cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(gates), Int32(hidden), 1, w.baseAddress!, Int32(hidden),
                                hp.baseAddress!, 1, 1, gp.baseAddress!, 1)
                } } }
                for j in 0..<hidden {
                    let input = sigmoid(g[j]), forget = sigmoid(g[hidden + j])
                    let cell = tanh(g[2 * hidden + j]), output = sigmoid(g[3 * hidden + j])
                    c[j] = forget * c[j] + input * cell
                    h[j] = output * tanh(c[j])
                    out[step * 2 * hidden + direction * hidden + j] = h[j]
                }
            }
        }
        return out
    }

    // MARK: Style-adjusted blocks

    /// AdaIN: each channel normalised over time, then scaled and shifted by
    /// amounts the style gives: (1 + γ) · x + β.
    private func adain(_ x: [Float], c: Int, t: Int, style: [Float], _ p: String) -> [Float] {
        let h = linear(style, rows: 1, W.get(p + ".fc.weight"), W.get(p + ".fc.bias"), out: 2 * c)
        var y = x
        instanceNorm(&y, c: c, t: t)
        y.withUnsafeMutableBufferPointer { yp in
            for ch in 0..<c {
                var gain = 1 + h[ch], shift = h[c + ch]
                let row = yp.baseAddress! + ch * t
                vDSP_vsmsa(row, 1, &gain, &shift, row, 1, vDSP_Length(t))
            }
        }
        return y
    }

    /// StyleTTS 2's AdainResBlk1d: two style-adjusted convolutions, with an
    /// optional doubling of the time resolution, added to a shortcut.
    private func adainResBlk(_ x: [Float], cin: Int, t: Int, cout: Int, style: [Float], upsample: Bool,
                             _ p: String) -> (y: [Float], t: Int) {
        var r = adain(x, c: cin, t: t, style: style, p + ".norm1")
        leakyRelu(&r, 0.2)
        var rt = t
        if upsample {
            (r, rt) = depthwiseTranspose(r, c: cin, t: t, W.get(p + ".pool.weight"), W.get(p + ".pool.bias"), k: 3,
                                         stride: 2, padding: 1, outputPadding: 1)
        }
        (r, rt) = conv1d(r, cin: cin, t: rt, W.get(p + ".conv1.weight"), W.get(p + ".conv1.bias"), cout: cout, k: 3, padding: 1)
        r = adain(r, c: cout, t: rt, style: style, p + ".norm2")
        leakyRelu(&r, 0.2)
        (r, rt) = conv1d(r, cin: cout, t: rt, W.get(p + ".conv2.weight"), W.get(p + ".conv2.bias"), cout: cout, k: 3, padding: 1)
        // The shortcut: nearest-neighbour upsampling, and a 1×1 convolution
        // when the width changes.
        var s = x, st = t
        if upsample {
            var doubled = [Float](repeating: 0, count: cin * 2 * t)
            for ch in 0..<cin { for i in 0..<t { doubled[ch * 2 * t + 2 * i] = x[ch * t + i]; doubled[ch * 2 * t + 2 * i + 1] = x[ch * t + i] } }
            s = doubled
            st = 2 * t
        }
        if cin != cout { s = conv1d(s, cin: cin, t: st, W.get(p + ".conv1x1.weight"), nil, cout: cout, k: 1).y }
        add(&r, s)
        scale(&r, Float(0.5).squareRoot())
        return (r, rt)
    }

    /// HiFi-GAN's residual block, style-adjusted, with Snake activations.
    private func adainResBlock1(_ x: inout [Float], c: Int, t: Int, k: Int, style: [Float], _ p: String) {
        for (n, dilation) in [1, 3, 5].enumerated() {
            var y = adain(x, c: c, t: t, style: style, "\(p).adain1.\(n)")
            snake(&y, c: c, t: t, W.get("\(p).alpha1.\(n)"))
            y = conv1d(y, cin: c, t: t, W.get("\(p).convs1.\(n).weight"), W.get("\(p).convs1.\(n).bias"), cout: c, k: k,
                       padding: (k - 1) * dilation / 2, dilation: dilation).y
            y = adain(y, c: c, t: t, style: style, "\(p).adain2.\(n)")
            snake(&y, c: c, t: t, W.get("\(p).alpha2.\(n)"))
            y = conv1d(y, cin: c, t: t, W.get("\(p).convs2.\(n).weight"), W.get("\(p).convs2.\(n).bias"), cout: c, k: k,
                       padding: (k - 1) / 2).y
            add(&x, y)
        }
    }

    // MARK: The generator (iSTFTNet)

    private func generator(_ input: [Float], t: Int, style: [Float], f0: [Float]) -> [Float] {
        let g = "decoder.generator."
        let upsample = 300, halfFrames = f0.count, samples = halfFrames * upsample
        // The harmonic source: sines at the pitch and its first eight
        // overtones, merged into one signal. The original adds a little
        // random noise and random starting phases while training; reading
        // aloud, as in Kokoro's own exported model, has none.
        let mix = W.get(g + "m_source.l_linear.weight"), mixBias = W.get(g + "m_source.l_linear.bias")[0]
        var harmonic = [Float](repeating: mixBias, count: samples)
        var phase = [Float](repeating: 0, count: halfFrames)
        var angles = [Float](repeating: 0, count: samples)
        // 1 where the half-frame is voiced (its pitch above 10 Hz), else 0.
        let voiced: [Float] = (0..<samples).map { f0[min($0 / upsample, halfFrames - 1)] > 10 ? 1 : 0 }
        for h in 0..<9 {
            // Phase at each half-frame: the running sum of cycles per sample
            // (wrapped to 0…1, as the original does), times 2π, scaled up.
            var cycles: Double = 0
            for f in 0..<halfFrames {
                var step = (Double(f0[f]) * Double(h + 1) / Self.sampleRate).truncatingRemainder(dividingBy: 1)
                if step < 0 { step += 1 }
                cycles += step
                phase[f] = Float(cycles * 2 * .pi * Double(upsample))
            }
            // Linear interpolation to every sample, then the sines at once;
            // silence where unvoiced.
            for n in 0..<samples {
                let position = max(0, (Float(n) + 0.5) / Float(upsample) - 0.5)
                let i0 = min(Int(position), halfFrames - 1), i1 = min(i0 + 1, halfFrames - 1)
                let blend = position - Float(i0)
                angles[n] = phase[i0] * (1 - blend) + phase[i1] * blend
            }
            var count = Int32(samples)
            angles.withUnsafeMutableBufferPointer { vvsinf($0.baseAddress!, $0.baseAddress!, &count) }
            var weight = mix[h] * 0.1
            vDSP_vmul(angles, 1, voiced, 1, &angles, 1, vDSP_Length(samples))
            vDSP_vsma(angles, 1, &weight, harmonic, 1, &harmonic, 1, vDSP_Length(samples))
        }
        var count = Int32(samples)
        harmonic.withUnsafeMutableBufferPointer { vvtanhf($0.baseAddress!, $0.baseAddress!, &count) }
        let (magnitude, angle, spectrumFrames) = kokoroSTFT(harmonic)
        let source = magnitude + angle // 22 × frames
        harmonic = []

        var x = input, xt = t
        let channels = [256, 128], rates = [10, 6], kernels = [20, 12]
        for stage in 0..<2 {
            leakyRelu(&x, 0.1)
            var noise: [Float]
            if stage == 0 {
                noise = conv1d(source, cin: 22, t: spectrumFrames, W.get(g + "noise_convs.0.weight"), W.get(g + "noise_convs.0.bias"),
                               cout: 256, k: 12, stride: 6, padding: 3).y
            } else {
                noise = conv1d(source, cin: 22, t: spectrumFrames, W.get(g + "noise_convs.1.weight"), W.get(g + "noise_convs.1.bias"),
                               cout: 128, k: 1).y
            }
            let noiseT = noise.count / channels[stage]
            adainResBlock1(&noise, c: channels[stage], t: noiseT, k: stage == 0 ? 7 : 11, style: style, g + "noise_res.\(stage)")
            (x, xt) = convTranspose1d(x, cin: channels[stage] * 2, t: xt, W.get(g + "ups.\(stage).weight"), W.get(g + "ups.\(stage).bias"),
                                      cout: channels[stage], k: kernels[stage], stride: rates[stage],
                                      padding: (kernels[stage] - rates[stage]) / 2)
            if stage == 1 { // reflection padding, one step at the start
                let c = channels[stage]
                var padded = [Float](repeating: 0, count: c * (xt + 1))
                for ch in 0..<c {
                    padded[ch * (xt + 1)] = x[ch * xt + 1]
                    for i in 0..<xt { padded[ch * (xt + 1) + i + 1] = x[ch * xt + i] }
                }
                x = padded
                xt += 1
            }
            precondition(xt == noiseT, "Kokoro: generator lengths differ (\(xt), \(noiseT))")
            add(&x, noise)
            noise = []
            // Three residual blocks (kernels 3, 7, 11), averaged. The sum
            // starts as the first block's own output, to keep one copy fewer
            // of these, the largest arrays, alive at once.
            var sum = x
            adainResBlock1(&sum, c: channels[stage], t: xt, k: 3, style: style, g + "resblocks.\(stage * 3)")
            for (j, k) in [(1, 7), (2, 11)] {
                var r = x
                adainResBlock1(&r, c: channels[stage], t: xt, k: k, style: style, g + "resblocks.\(stage * 3 + j)")
                add(&sum, r)
            }
            x = []
            scale(&sum, 1.0 / 3)
            x = sum
        }
        leakyRelu(&x, 0.01)
        let spectrum = conv1d(x, cin: 128, t: xt, W.get(g + "conv_post.weight"), W.get(g + "conv_post.bias"), cout: 22, k: 7, padding: 3).y
        return kokoroISTFT(spectrum, frames: xt)
    }
}

// MARK: - Operations

/// x (rows × in) · Wᵀ (W: out × in) + b → (rows × out).
private func linear(_ x: [Float], rows: Int, _ w: [Float], _ b: [Float]?, out: Int) -> [Float] {
    let width = w.count / out
    var y = [Float](repeating: 0, count: rows * out)
    if let b { for r in 0..<rows { for o in 0..<out { y[r * out + o] = b[o] } } }
    x.withUnsafeBufferPointer { xp in w.withUnsafeBufferPointer { wp in y.withUnsafeMutableBufferPointer { yp in
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(out), Int32(width), 1, xp.baseAddress!, Int32(width),
                    wp.baseAddress!, Int32(width), b == nil ? 0 : 1, yp.baseAddress!, Int32(out))
    } } }
    return y
}

/// Matrix entries a working buffer may hold (8 MB), so long sentences do
/// not need large temporary memory.
private let workingLimit = 2_000_000

/// 1-D convolution of x (cin × t) by w (cout × cin × k): the inputs each
/// output step sees laid out as columns (im2col), a span of time at a time,
/// then one matrix product per span.
private func conv1d(_ x: [Float], cin: Int, t: Int, _ w: [Float], _ b: [Float]?, cout: Int, k: Int,
                    stride: Int = 1, padding: Int = 0, dilation: Int = 1) -> (y: [Float], t: Int) {
    let tout = (t + 2 * padding - dilation * (k - 1) - 1) / stride + 1
    var y = [Float](repeating: 0, count: cout * tout)
    let span = max(16, min(tout, workingLimit / (cin * k)))
    var columns = [Float](repeating: 0, count: cin * k * span)
    var part = [Float](repeating: 0, count: cout * span)
    var start = 0
    while start < tout {
        let n = min(span, tout - start)
        columns.withUnsafeMutableBufferPointer { cp in x.withUnsafeBufferPointer { xp in
            for c in 0..<cin {
                for j in 0..<k {
                    let row = (c * k + j) * n, base = c * t
                    if stride == 1 {
                        // One block copy, with zeros where the window runs
                        // off either end (most of the model's time was
                        // here, copying one value at a time).
                        let first = start - padding + j * dilation // source of column 0
                        let lo = max(0, -first), hi = min(n, t - first)
                        if lo > 0 { (cp.baseAddress! + row).update(repeating: 0, count: min(lo, n)) }
                        if hi > lo { (cp.baseAddress! + row + lo).update(from: xp.baseAddress! + base + first + lo, count: hi - lo) }
                        if hi < n { (cp.baseAddress! + row + max(hi, lo)).update(repeating: 0, count: n - max(hi, lo)) }
                    } else {
                        for i in 0..<n {
                            let source = (start + i) * stride - padding + j * dilation
                            cp[row + i] = (source >= 0 && source < t) ? xp[base + source] : 0
                        }
                    }
                }
            }
        } }
        w.withUnsafeBufferPointer { wp in columns.withUnsafeBufferPointer { cp in part.withUnsafeMutableBufferPointer { pp in
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(cout), Int32(n), Int32(cin * k), 1, wp.baseAddress!,
                        Int32(cin * k), cp.baseAddress!, Int32(n), 0, pp.baseAddress!, Int32(n))
        } } }
        y.withUnsafeMutableBufferPointer { yp in part.withUnsafeBufferPointer { pp in
            for o in 0..<cout {
                var bias = b?[o] ?? 0
                vDSP_vsadd(pp.baseAddress! + o * n, 1, &bias, yp.baseAddress! + o * tout + start, 1, vDSP_Length(n))
            }
        } }
        start += n
    }
    return (y, tout)
}

/// Transposed 1-D convolution of x (cin × t) by w (cin × cout × k): each
/// input step's contribution computed by one matrix product (a span of time
/// at a time), then added into place.
private func convTranspose1d(_ x: [Float], cin: Int, t: Int, _ w: [Float], _ b: [Float]?, cout: Int, k: Int,
                             stride: Int, padding: Int) -> (y: [Float], t: Int) {
    let tout = (t - 1) * stride - 2 * padding + k
    var y = [Float](repeating: 0, count: cout * tout)
    let span = max(16, min(t, workingLimit / (cout * k)))
    var slice = [Float](repeating: 0, count: cin * span)
    var columns = [Float](repeating: 0, count: cout * k * span)
    var start = 0
    while start < t {
        let n = min(span, t - start)
        for c in 0..<cin { for i in 0..<n { slice[c * n + i] = x[c * t + start + i] } }
        // columns ((cout·k) × n) = Wᵀ ((cout·k) × cin) · slice (cin × n)
        w.withUnsafeBufferPointer { wp in slice.withUnsafeBufferPointer { sp in columns.withUnsafeMutableBufferPointer { cp in
            cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(cout * k), Int32(n), Int32(cin), 1, wp.baseAddress!,
                        Int32(cout * k), sp.baseAddress!, Int32(n), 0, cp.baseAddress!, Int32(n))
        } } }
        for o in 0..<cout {
            for j in 0..<k {
                let row = (o * k + j) * n
                for i in 0..<n {
                    let target = (start + i) * stride - padding + j
                    if target >= 0 && target < tout { y[o * tout + target] += columns[row + i] }
                }
            }
        }
        start += n
    }
    if let b { for o in 0..<cout { for i in 0..<tout { y[o * tout + i] += b[o] } } }
    return (y, tout)
}

/// A transposed convolution applied to each channel on its own (w: c × 1 × k).
private func depthwiseTranspose(_ x: [Float], c: Int, t: Int, _ w: [Float], _ b: [Float], k: Int,
                                stride: Int, padding: Int, outputPadding: Int) -> (y: [Float], t: Int) {
    let tout = (t - 1) * stride - 2 * padding + k + outputPadding
    var y = [Float](repeating: 0, count: c * tout)
    for ch in 0..<c {
        for i in 0..<t {
            let v = x[ch * t + i]
            for j in 0..<k {
                let target = i * stride - padding + j
                if target >= 0 && target < tout { y[ch * tout + target] += v * w[ch * k + j] }
            }
        }
        for i in 0..<tout { y[ch * tout + i] += b[ch] }
    }
    return (y, tout)
}

private func leakyRelu(_ x: inout [Float], _ slope: Float) {
    // slope·x + (1 − slope)·max(x, 0), in vector operations.
    var positive = [Float](repeating: 0, count: x.count)
    var zero: Float = 0, a = slope, b = 1 - slope
    let n = vDSP_Length(x.count)
    x.withUnsafeMutableBufferPointer { xp in
        vDSP_vthres(xp.baseAddress!, 1, &zero, &positive, 1, n)
        vDSP_vsmsma(xp.baseAddress!, 1, &a, positive, 1, &b, xp.baseAddress!, 1, n)
    }
}

/// Each channel of x (c × t) normalised to mean 0 and variance 1 over time.
private func instanceNorm(_ x: inout [Float], c: Int, t: Int, eps: Float = 1e-5) {
    x.withUnsafeMutableBufferPointer { p in
        for ch in 0..<c {
            let row = p.baseAddress! + ch * t
            var mean: Float = 0, meanSquare: Float = 0
            vDSP_meanv(row, 1, &mean, vDSP_Length(t))
            vDSP_measqv(row, 1, &meanSquare, vDSP_Length(t))
            var scale = 1 / (max(0, meanSquare - mean * mean) + eps).squareRoot()
            var shift = -mean * scale
            vDSP_vsmsa(row, 1, &scale, &shift, row, 1, vDSP_Length(t))
        }
    }
}

/// Layer norm over the last dimension of x (rows × n), with optional gain
/// and bias.
private func layerNorm(_ x: inout [Float], rows: Int, n: Int, _ g: [Float]?, _ b: [Float]?, eps: Float) {
    for r in 0..<rows {
        var mean: Float = 0
        for i in 0..<n { mean += x[r * n + i] }
        mean /= Float(n)
        var variance: Float = 0
        for i in 0..<n { let d = x[r * n + i] - mean; variance += d * d }
        let scale = 1 / (variance / Float(n) + eps).squareRoot()
        for i in 0..<n {
            var v = (x[r * n + i] - mean) * scale
            if let g { v *= g[i] }
            if let b { v += b[i] }
            x[r * n + i] = v
        }
    }
}

/// (rows × cols) → (cols × rows).
private func transpose(_ x: [Float], rows: Int, cols: Int) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    vDSP_mtrans(x, 1, &y, 1, vDSP_Length(cols), vDSP_Length(rows))
    return y
}

/// x += y. (Written with a buffer pointer: passing `x` both ways to vDSP
/// would make Swift copy the whole array first.)
private func add(_ x: inout [Float], _ y: [Float]) {
    x.withUnsafeMutableBufferPointer { p in vDSP_vadd(p.baseAddress!, 1, y, 1, p.baseAddress!, 1, vDSP_Length(p.count)) }
}

/// x *= factor.
private func scale(_ x: inout [Float], _ factor: Float) {
    var factor = factor
    x.withUnsafeMutableBufferPointer { p in vDSP_vsmul(p.baseAddress!, 1, &factor, p.baseAddress!, 1, vDSP_Length(p.count)) }
}

@inline(__always) private func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

/// Snake: x + sin²(αx)/α, with an α for each channel.
private func snake(_ x: inout [Float], c: Int, t: Int, _ alpha: [Float]) {
    var scratch = [Float](repeating: 0, count: t)
    var count = Int32(t)
    x.withUnsafeMutableBufferPointer { xp in scratch.withUnsafeMutableBufferPointer { sp in
        for ch in 0..<c {
            let row = xp.baseAddress! + ch * t, s = sp.baseAddress!
            var a = alpha[ch], inverse = 1 / alpha[ch]
            vDSP_vsmul(row, 1, &a, s, 1, vDSP_Length(t))          // αx
            vvsinf(s, s, &count)                                  // sin(αx)
            vDSP_vsq(s, 1, s, 1, vDSP_Length(t))                  // sin²(αx)
            vDSP_vsma(s, 1, &inverse, row, 1, row, 1, vDSP_Length(t)) // x + sin²/α
        }
    } }
}

// MARK: - Short-time Fourier transform (20-point, hop 5, periodic Hann, centred)

private let fftSize = 20, hop = 5, bins = 11
private let hann: [Float] = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(fftSize)) }

/// The spectrum's magnitude and phase (each bins × frames), as torch.stft
/// with reflection padding.
public func kokoroSTFT(_ x: [Float]) -> (magnitude: [Float], phase: [Float], frames: Int) {
    let pad = fftSize / 2, n = x.count
    func at(_ i: Int) -> Float {
        var j = i - pad
        if j < 0 { j = -j }
        if j >= n { j = 2 * (n - 1) - j }
        return x[min(max(j, 0), n - 1)]
    }
    let frames = n / hop + 1
    var magnitude = [Float](repeating: 0, count: bins * frames), phase = magnitude
    var windowed = [Float](repeating: 0, count: fftSize)
    for f in 0..<frames {
        for i in 0..<fftSize { windowed[i] = at(f * hop + i) * hann[i] }
        for b in 0..<bins {
            var re: Float = 0, im: Float = 0
            for i in 0..<fftSize {
                let a = -2 * Float.pi * Float((b * i) % fftSize) / Float(fftSize)
                re += windowed[i] * cos(a)
                im += windowed[i] * sin(a)
            }
            magnitude[b * frames + f] = (re * re + im * im).squareRoot()
            phase[b * frames + f] = atan2(im, re)
        }
    }
    return (magnitude, phase, frames)
}

/// Sound from x (22 × frames): the log-magnitude in the first 11 rows and,
/// through a sine, the phase in the rest.
public func kokoroISTFT(_ x: [Float], frames: Int) -> [Float] {
    var magnitude = [Float](repeating: 0, count: bins * frames), phase = magnitude
    for i in 0..<(bins * frames) {
        magnitude[i] = exp(x[i])
        phase[i] = sin(x[bins * frames + i])
    }
    return kokoroInverseSTFT(magnitude: magnitude, phase: phase, frames: frames)
}

/// The inverse of `kokoroSTFT`, as torch.istft: each frame's one-sided
/// spectrum back to 20 samples, overlap-added with the window, divided by
/// the window's summed square, and the centring padding cut off.
public func kokoroInverseSTFT(magnitude: [Float], phase: [Float], frames: Int) -> [Float] {
    let length = fftSize + hop * (frames - 1)
    var out = [Float](repeating: 0, count: length), envelope = out
    // cos and sin of 2π·b·i/N for every bin and sample, worked out once.
    var cosines = [Float](repeating: 0, count: bins * fftSize), sines = cosines
    for b in 0..<bins {
        for i in 0..<fftSize {
            let a = 2 * Float.pi * Float((b * i) % fftSize) / Float(fftSize)
            cosines[b * fftSize + i] = cos(a)
            sines[b * fftSize + i] = sin(a)
        }
    }
    var re = [Float](repeating: 0, count: bins), im = re
    for f in 0..<frames {
        for b in 0..<bins {
            let m = magnitude[b * frames + f], p = phase[b * frames + f]
            // A one-sided spectrum: every bin but the first and last stands
            // for two.
            let weight: Float = (b == 0 || b == bins - 1) ? 1 : 2
            re[b] = weight * m * cos(p)
            im[b] = weight * m * sin(p)
        }
        for i in 0..<fftSize {
            var s: Float = 0
            for b in 0..<bins { s += re[b] * cosines[b * fftSize + i] - im[b] * sines[b * fftSize + i] }
            out[f * hop + i] += s / Float(fftSize) * hann[i]
            envelope[f * hop + i] += hann[i] * hann[i]
        }
    }
    for i in 0..<length where envelope[i] > 1e-11 { out[i] /= envelope[i] }
    return Array(out[(fftSize / 2)..<(length - fftSize / 2)])
}

// MARK: - Voices

/// A Kokoro voice: 510 rows of 256 style values, the row chosen by the
/// length of what is said (`style(forTokens:)`). The .bin files in the
/// voice pack are these rows as little-endian Float32.
public struct KokoroVoicePack {
    public let name: String
    private let rows: [Float]

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url), data.count == 510 * 256 * 4 else { return nil }
        name = url.deletingPathExtension().lastPathComponent
        rows = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// The style for a piece of `count` tokens (the 0s at the ends not
    /// counted, as Kokoro's own pipeline does).
    public func style(forTokens count: Int) -> [Float] {
        let row = min(max(count - 2, 0), 509)
        return Array(rows[(row * 256)..<((row + 1) * 256)])
    }

    /// Voices are British ("bf_", "bm_") or American ("af_", "am_").
    public var isBritish: Bool { name.hasPrefix("b") }
}
