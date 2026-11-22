# Read aloud

The speaker button reads the book aloud from the current page with Apple's
voices, underlining the word being read and turning pages as it goes.
iOS first; the Mac follows with the same shared code. What ships is in "How
it works" below.

## The natural voice: parked (22 Nov 2026)

A natural-sounding English voice (Kokoro-82M) was built and worked in the iOS
Simulator, then **parked** by the user: more work and more compromises than
expected for now, though a good direction. The work is kept, complete, on the
branch **`kokoro-natural-voice`** (commit `c0cc641`, version 0.8.35; draft PR
shahidhussain/platen-reader#21 was closed in its favour). Everything learned
is below, so it can be picked up again.

What it would cost (the compromises):
- **App size for everyone:** ONNX Runtime adds about 40 MB to the installed
  app and about 10 MB to the download, whether or not the voice is used.
- **Telemetry to switch off:** ONNX Runtime's Apple build sends Microsoft
  telemetry by default (see below). It can be switched off and the switch
  checked, but it is a standing risk with every update.
- **Fragile supply:** Microsoft's usual homes for the iOS build were
  unreachable; the build came from its NuGet package.
- **App Store Connect work** for the download (Background Assets, iOS 26.4
  and later only), and measurements still to make on the oldest iPhone.
- **Quality:** the user could not tell the int8 model from fp16 in a short
  sample; a longer listen is needed before choosing.

The spec's Read aloud decision now covers Apple's voices only; the voice
download is not an exception in force while this is parked.

## The natural voice: what was learned

### Step 0: licences and runtime (22 Nov 2026)

Nothing GPL may ship, in code or data. eSpeak NG and piper-phonemize are GPL
and are not used anywhere.

| Part | Licence | Notes |
| --- | --- | --- |
| Kokoro-82M weights and voices (hexgrad/Kokoro-82M) | Apache-2.0 | fp16, about 165 MB; English voices only (American `a*`, British `b*`) |
| hexgrad/kokoro (reference code) | Apache-2.0 | Not shipped; the reference for the pipeline |
| hexgrad/misaki (English G2P: lexicons and rules) | Apache-2.0 | Not MIT, as first thought; Apache-2.0 is equally fine. Its optional eSpeak fallback is not used |
| FluidInference/FluidAudio (Core ML Kokoro, "KokoroAne") | Apache-2.0 | Chosen runtime, vendored in part (see below) |
| FluidAudio's `LuxTtsG2pResources` | eSpeak-derived (GPL-3.0-or-later) and CC-BY-SA-4.0 data | The reason FluidAudio is **not** added as a package: its `TTS` trait always links this target |
| FluidAudio's `NemoTextProcessing` | Prebuilt binary | Not needed; left out |
| mlalma/kokoro-ios (KokoroSwift, MLX) | MIT | Considered; see below |
| mlalma/MisakiSwift | Apache-2.0 | Considered (MLX) |
| ml-explore/mlx-swift | MIT | Considered |
| mlalma/eSpeakNGSwift | GPL-3.0 | Commented out of kokoro-ios's manifest; never used |

### Runtimes considered

- **KokoroSwift (MLX, MIT).** No GPL. Runs Kokoro on the GPU through Metal.
  iOS does not let a background app submit GPU work, so it cannot keep
  reading at the lock screen, which read aloud must. MLX's CPU path is too
  slow for real time on phones.
- **FluidAudio's KokoroAne (Core ML, Apache-2.0).** Runs on the Neural Engine
  and CPU, which background apps may use, so reading carries on with the
  screen locked. English G2P is misaki's lexicons with a Core ML
  grapheme-to-phoneme model for unknown words (no eSpeak). The package
  itself cannot be used (see `LuxTtsG2pResources` above), so the English
  parts are vendored: the pipeline, model store, voice packs, English
  phonemiser and its British fallback, and the G2P model wrapper, under
  their Apache-2.0 headers, with FluidAudio's NOTICE and licence in the
  app's acknowledgements. French, Spanish, Japanese and Mandarin are left
  out (their lexicons are eSpeak-derived, or not needed).

**Choice: vendored KokoroAne (Core ML).** Recorded 22 Nov 2026, and
**reopened the same day** (see "Core ML on iOS: crashes" below).

### Core ML on iOS: crashes (found 22 Nov 2026)

Tracing KokoroAne's English path (FluidAudio at
`3ecbf6b3a06a69afc938c298e561b4257325429f`) turned up its own "Known OS
issues" notes:

- Core ML's Kokoro chain crashes inside Apple's BNNS library on iOS 26.4 to
  26.6 and on iOS 27 (`EXC_BAD_ACCESS` / `SIGSEGV` in `libBNNS`). FluidAudio
  says: "there is currently no OS version or routing on iOS that is
  demonstrated safe for long sessions" (their issue #889 asks whether to
  turn it off on iOS by default). An iPhone XR (A12, iOS 18) was killed for
  memory while loading the Vocoder (#979).
- On iOS 27, Core ML may use the Neural Engine in the background only with
  the `com.apple.developer.background-tasks.continued-processing.inference`
  entitlement.
- Sizes (compiled models only): the seven-stage chain about 90 MB, plus
  voices (0.5 MB each) and the English G2P (BART model, Misaki lexicon). The
  newer "v3" adds about 120 MB and uses the GPU on iOS 26 and earlier, so
  it cannot read in the background.

A reader that may crash partway through a chapter cannot ship, so the
Core ML route is on hold.

### The other route: ONNX Runtime on the CPU

Kokoro's published ONNX model (`onnx-community/Kokoro-82M-v1.0-ONNX`,
Apache-2.0; `model_fp16.onnx` 163.2 MB, `model_quantized.onnx` 92.4 MB, the
"about 165 MB" in the spec) run by ONNX Runtime (MIT) on the CPU: allowed in
the background, and ONNX Runtime has its own CPU kernels (not BNNS). Against
it: Microsoft's Swift package repository
(`microsoft/onnxruntime-swift-package-manager`) is no longer reachable, so its
binary (an xcframework, tens of MB) would be packaged here and added to every
install, and its speed on an iPhone's CPU is unmeasured (no Python wheel for
this Mac's Python to time it here). The English G2P would be misaki's
lexicons (Apache-2.0) in Swift, with CMUdict (BSD) for words they lack.

**Chosen by the user, 22 Nov 2026: ONNX Runtime on the CPU.**

### ONNX Runtime: the build in use

- ONNX Runtime 1.32.0 (MIT) from Microsoft's NuGet package
  (`Microsoft.ML.OnnxRuntime`, signed by Microsoft Corporation and
  countersigned by nuget.org; SHA-256 pinned in `scripts/fetch-onnxruntime.sh`).
  Its GitHub repository, Swift package and `download.onnxruntime.ai` (an
  Azure CDN name with the wrong certificate, and a 404 behind it) were all
  unreachable. The script adds a module map so Swift can use the C API, and
  puts it in `Vendor/onnxruntime/` (not in git: the static library is 49 MB
  for devices, about 100 MB each for the Simulator and Mac Catalyst). CI runs
  the script before the iOS build. No macOS slice: the Mac's natural voice
  will use the package's `libonnxruntime.dylib`.
- **Size.** The Release iOS app's executable grows from 5.7 MB to 45.1 MB;
  the zipped app (about what is downloaded) from about 3 MB to 12.7 MB, for
  everyone, whether or not they use the voice. A minimal build with only
  Kokoro's operators would be far smaller, but needs ONNX Runtime's sources.
- **ONNX Runtime's telemetry.** Its Apple build carries Microsoft's telemetry
  client (1DS) and, as its header says, "Telemetry events are on by
  default". Left on, the app connected to `mobile.events.data.microsoft.com`
  (4.150.223.96, Microsoft Corporation) as soon as the model loaded.
  `KokoroModel` sets `ORT_DISABLE_TELEMETRY` before ONNX Runtime does
  anything and calls `DisableTelemetryEvents` once its environment exists;
  with both, `scripts/check-no-network.sh` sees no socket at all while
  reading and quitting. Run it after any ONNX Runtime update.

### The model and the text

- `kokoro.onnx`: Kokoro-82M v1.0, int8 (`model_quantized.onnx`, 92.4 MB), not
  fp16 (163.2 MB): twice as fast and 300 MB less memory, which matters on
  4 GB iPhones. Samples of both: `build/kokoro-samples/` (from the Mac test).
- English text: Misaki's lexicons through the vendored MisakiSwift code
  (`PlatenReader/Shared/Kokoro/Misaki`, Apache-2.0; no MLX), and for words
  they lack `KokoroFallback`: the CMU Pronouncing Dictionary (BSD), a word
  without a common ending, an acronym spelt out, else left unsaid. British
  voices (`bf_`, `bm_`) use Misaki's British lexicons; the CMU fallback is
  made non-rhotic for them.

### Measurements (22 Nov 2026)

| Where | Model | Threads | Real-time factor | Peak memory | First audio |
| --- | --- | --- | --- | --- | --- |
| Mac (M3 Pro), C++ test | int8 | 4 / 2 / 1 | 0.09 / 0.14 / 0.22 | 515 MB | |
| Mac (M3 Pro), C++ test | fp16 | 4 / 2 / 1 | 0.19 / 0.32 / 0.58 | 800 MB | |
| Mac, Swift test (text + model) | int8 | 2 | 0.13–0.15 | 440 MB | |
| iOS Simulator, in the app | int8 | 2 | 0.13–0.16 | | model 0.25 s + first sentence 0.24 s |
| iPhone (oldest supported) | int8 | 2 | to measure | to measure | to measure |

(Real-time factor: time to make a second of speech; under 1 is faster than
it is spoken.) The app logs each sentence's figure to the diagnostics file
("natural voice: 3.7 s of speech in 507 ms"), so a device's numbers come from
reading a chapter and sharing the file. The minimum device is set for now
by memory (`KokoroVoice.hasMemoryForIt`: 6 GB or more), until measured.

### The voice pack

`scripts/make-kokoro-pack.py` builds `build/kokoro-pack/` from pinned,
hashed sources (Kokoro and its voices from onnx-community, Kokoro's symbol
table from hexgrad, Misaki's lexicons from hexgrad/misaki, CMUdict), with
their licences and a NOTICE: 112.8 MB unpacked, 70.8 MB zipped
(`build/kokoro-pack.zip`, SHA-256 printed). Eight voices: British Emma,
Isabella, George, Lewis; American Heart, Bella, Michael, Fenrir.

### To do in App Store Connect (yours)

The iOS download is Apple-hosted Background Assets (iOS 26.4 and later in
the code; iOS 17 to 26.3 get Apple's voices only). Until these are done the
app does not offer the download (Debug builds can try it from a folder:
`PLATEN_KOKORO_DOWNLOAD_FROM`):
1. Add the Background Assets capability, an App Group, and a Background
   Download extension target (Apple-hosted, managed) in Xcode.
2. Add the Info.plist keys `BAHasManagedAssetPacks`, `BAUsesAppleHosting`,
   `BAAppGroupID`, and Platen's own `PlatenKokoroAssetPack` = YES.
3. Package `build/kokoro-pack/` as the asset pack "KokoroVoice" (`xcrun
   ba-package`) and upload it with the build.


### Hosting the voice

- **iOS:** Apple-hosted Background Assets (an asset pack uploaded with the
  build in App Store Connect). Apple-hosted packs need **iOS 26** or later.
  The app supports iOS 17, so on iOS 17 to 25 the Kokoro voice is not
  offered: English books read with Apple's voices, with no first-tap
  dialog, and Settings shows only Apple's voices. Uploading the asset pack
  is a step in App Store Connect (see "Still to do").
- **Mac (direct download):** a GitHub release asset, checked against a
  SHA-256 pinned in the app before it is used. No other network call.

## How it works

- **Text and marks (the shell).** foliate's `tts.js` (vendored at the pinned
  commit) splits each section into blocks and sentences.
  `modules/readaloud.js` sends Swift about 20 sentences at a time from the
  first sentence on the current page, reading ahead into later chapters
  (documents loaded off screen; iOS suspends the web view in the background),
  each sentence with its CFI. As each is spoken the page turns to it, and the
  word being read is underlined (Apple's voices report each word; a sentence
  is underlined whole when no word timing comes): a thin accent-coloured
  line drawn as a foliate annotation. Not a highlight, which looked too heavy
  and means something else in a book (the reader asked, 22 Nov 2026).
- **Speech (Swift, Shared).** `ReadAloud.swift` holds `ReadAloudController`
  (the queue of sentences, asking for more while 40 remain), the
  `SpeechEngine` protocol, `SpeechEngineChooser` (language and choice) and
  `AppleVoices` (Premium, then Enhanced, then default, for the book's
  language); `AppleSpeechEngine` speaks with AVSpeechSynthesizer.
- **iOS.** The speaker button is in the reader's top bar (Pause and Resume
  while reading; Stop Reading on a long press); `ReadAloudAudio` holds the
  audio session (spoken audio, background playback), the lock screen's Now
  Playing and its controls, and pauses for calls and unplugged headphones.
  Settings › Read Aloud: Apple voice with Play Sample, speed, and where
  better Apple voices come from.
- **PDFs.** Not read aloud yet: the speaker button is only in books.

## What is stored

- The Apple voice chosen in Settings (or none, for the best installed), the
  speed, and a flag per language once the note about better voices has been
  shown: global settings (docs/per-book-data.md). Nothing per book.

## Done (22 Nov 2026, 0.8.34)

- Spec, CLAUDE.md and README: the decisions and the second network exception.
- foliate's `tts.js` vendored; `modules/readaloud.js`: blocks and sentences
  from the current page, reading ahead about 40 sentences and into later
  chapters (documents loaded off screen), each sentence marked by its CFI and
  highlighted as a foliate annotation as it is spoken, turning pages and
  chapters as it goes. `platen.readAloudPreview()` for checks.
- Shared: `ReadAloud.swift` (`SpeechEngine`, `SpeechEngineChooser`,
  `AppleVoices`, `ReadAloudController`), `AppleSpeechEngine`,
  `ReadAloudSettings`; `BookSession.startReadAloud` and the bridge messages
  `readAloudBlock` / `readAloudEnd`. Tests: `ReadAloudTests` (engine choice,
  the book's language, Apple's voice ranking, the sentence queue).
- iOS: the speaker button (top bar, right; Pause and Resume while reading;
  Stop Reading on a long press), the first-tap dialog for English books (in
  place, not reached until the natural voice is offered), the once-only note
  about better Apple voices, Settings › Read Aloud (Apple voice with Play
  Sample, speed, the note), background audio and the lock screen
  (`ReadAloudAudio`), pausing for calls and unplugged headphones.
- Fixtures `french.epub` and `mixed-language.epub` with corpus checks; the
  matrix's `read-aloud` case (the button, playing, paused, stopped).

## Still to do

- Reading at the lock screen on a device (the Simulator cannot lock).
- The Mac's speaker button and Settings.
- PDFs (PDFKit's page text, no highlighting).
- The natural voice, if it is taken up again: see the parked section above
  and the branch `kokoro-natural-voice`.
