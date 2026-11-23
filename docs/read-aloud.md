# Read aloud

The speaker button reads the book aloud from the current page with Apple's
voices, underlining the word being read and turning pages as it goes.
iOS first; the Mac follows with the same shared code. What ships is in "How
it works" below.

## The natural voice: taken up again, without a runtime (22 Nov 2026)

A natural-sounding English voice (Kokoro-82M) was first built on ONNX
Runtime (branch `kokoro-natural-voice`, commit `c0cc641`) and **parked**: ONNX
Runtime added about 40 MB to every install and sent Microsoft telemetry
unless switched off. Hearing Apple's voice, the user found it not good
enough to ship as read aloud, and asked whether the brief could be met
another way: downloaded on demand, English only, relatively small,
absolutely no telemetry, and ideally no larger app for those who do not use
it.

It can: **Kokoro now runs on our own Swift code on Apple's Accelerate**
(`PlatenCore/Sources/Kokoro`, "Running the model" below). There is no
machine-learning runtime in the app, so nothing that could report anywhere.
The app grows by a few hundred lines of code; the voice is an 82 MB download.
Branch `kokoro-accelerate`.

The download is an agreed network exception (the user, 22 Nov 2026): it
happens only on the reader's explicit request, after a dialog that says in
plain words what is downloaded and how big it is, with a progress sheet.
Still open: the App Store Connect steps (below) are the user's, and speed
and memory need measuring on an iPhone.

**Trying it on an iPhone before the download exists** (Debug builds): run
`python3 scripts/make-kokoro-pack.py`, then in Finder select the iPhone,
open Files, and drag `build/kokoro-pack` onto Platen Reader. At its next
launch the app moves the folder to where a downloaded pack lives
(`KokoroDownload.adoptCopiedPack`), and English books can be read with the
natural voice (Settings › Read Aloud, or the dialog at the first tap).

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

(The table and sections below record the first round, 22 Nov 2026. FluidAudio
and ONNX Runtime are no longer used; "Running the model" is what ships.)

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

**Chosen by the user, 22 Nov 2026: ONNX Runtime on the CPU.** Superseded the
same day by our own code on Accelerate (below).

### ONNX Runtime: the build that was tried

- ONNX Runtime 1.32.0 (MIT) from Microsoft's NuGet package
  (`Microsoft.ML.OnnxRuntime`, signed by Microsoft Corporation and
  countersigned by nuget.org; SHA-256 pinned in `scripts/fetch-onnxruntime.sh`, since removed).
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

### Running the model: our own code on Accelerate (22 Nov 2026)

`KokoroModel` (`PlatenCore/Sources/Kokoro/KokoroModel.swift`) is a port of
hexgrad's PyTorch Kokoro (Apache-2.0; it builds on StyleTTS 2, iSTFTNet and
HiFi-GAN, all MIT) to plain Swift: Albert (one shared layer applied 12
times), the duration and prosody predictors (bidirectional LSTMs, AdaIN
residual blocks), the text encoder, the decoder and the iSTFTNet generator
(harmonic source, two upsampling stages, a 20-point inverse STFT).
Convolutions are matrix products (`cblas_sgemm` over im2col columns, in
spans of time so working buffers stay under 8 MB); LSTMs do their input
products at once and step the recurrence with `cblas_sgemv`.

- **A module of its own** (`Kokoro` in the PlatenCore package), compiled with
  `-O` even in Debug builds: unoptimised it is about 60 times slower
  (real-time factor 21), too slow to try in the Simulator.
- **The weights** (`kokoro-weights.bin` and `.json` in the voice pack) are
  converted by `scripts/make-kokoro-pack.py` from hexgrad's own checkpoint
  (`kokoro-v1_0.pth`, read without PyTorch: a pickle that refuses anything
  but tensors), with weight normalisation folded in and every weight of 4096
  values or more stored as int8 with a scale per row. The file is
  memory-mapped, and a layer's weights are turned into floats only while it
  runs, so the 82 MB never count as the app's own memory.
- **Checked against ONNX Runtime's fp32 model** on the same tokens: the same
  durations (equal lengths) and the same pitch curve; the spectrum differs
  from it about as much as ONNX's own fp16 model does from its fp32 one,
  which the user could not tell apart. The waveforms differ sample by
  sample only because the harmonic source integrates the pitch, so tiny
  float differences become phase. With int8 weights the difference is a
  little larger, and still well under that of the int8 ONNX model the user
  heard.
- **A trap in the ONNX export.** onnx-community's `model.onnx` divides its
  inverse STFT by the window's summed square over the first 20 samples only
  (`window_sum` was traced at that length), so everything after is 1.5×
  louder than hexgrad's model. Ours follows torch.istft, as the original
  does. Compare against the PyTorch model's behaviour, not the export's
  levels.
- **No randomness.** The original adds noise and random phases to the
  harmonic source while training; like the export, reading uses none, so the
  same text always sounds the same.
- **Pieces of about ten seconds.** Memory grows with the length of what is
  made at once (about 15 MB per second of speech, mostly the generator's
  last stage), so `KokoroText` splits a sentence of more than 130 sounds at
  its last pause before that (Kokoro's own limit is 510). This also starts a
  long first sentence sooner.
- **Word timing for the underline.** Kokoro predicts how many 600-sample
  frames each sound lasts; `KokoroText.pieces` knows which sounds belong to
  which word of the sentence (Misaki's tokens keep their text), so
  `KokoroSpeechEngine` knows when each word starts and reports it as the
  player reaches it (checked in the Simulator: each word within 40 ms of its
  audio).

### Cadence: the voices differ (22 Nov 2026)

On the iPhone the reader found Emma (`bf_emma`) flat: every sentence ended on
much the same pitch. Measured on the Mac (a pitch track of the same seven
sentences): Emma's sentence endings all fall to between 2.5 and 4 semitones
below her median, Isabella's likewise, while Heart's (`af_heart`, the voice
hexgrad grades highest) range from 4 below to 5 above, and Bella's similarly.
The int8 weights change nothing here (fp32 and int8 give the same endings to
a tenth of a semitone). Reading several sentences in one piece, as Kokoro's
own pipeline does, adds only the odd rise for Emma. Kokoro's British voices
had far less training data than its American ones. Options: an American
voice; Heart's voice with British pronunciation (Misaki's British lexicon);
or a blend of voices (their 256 style values averaged). Samples:
`build/kokoro-samples/cadence/`.

### The model and the text
- English text: Misaki's lexicons through the vendored MisakiSwift code
  (`PlatenReader/Shared/Kokoro/Misaki`, Apache-2.0; no MLX), and for words
  they lack `KokoroFallback`: the CMU Pronouncing Dictionary (BSD), as
  written, without accents and in the other spelling (British or
  American); a possessive's owner; a word without a common ending; two
  known words joined; an acronym spelt out; and last English spelling rules
  (`KokoroLetterRules`, after the US Naval Research Laboratory's
  letter-to-sound rules of 1976, public domain, written afresh), so that no
  word is left unsaid. Before the rules, 343 of 42,749 words in the
  reader's sample books went unsaid (mostly names: Grubach, Bürstner,
  Feckle); after, none. "a" is the article ("ɐ") unless tagged a noun. British
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
| **Accelerate (ours), Mac (M3 Pro), one core** | int8 weights | 1 | 0.32–0.35 | 150–350 MB* | |
| **Accelerate (ours), iOS Simulator, in the app** | int8 weights | | 0.87 | | first sentence (5.5 s) in 4.8 s |
| **Accelerate (ours), iPhone 16 Pro Max, in the app** | int8 weights | | 0.27 (0.24–0.76), before the vectorising below | | 1.1 s |
| **Accelerate (ours), vectorised, Mac (M3 Pro)** | int8 weights | 1 | 0.13 | | |

\* With the text side: Misaki's lexicons take about 105 MB of it; the model
about 40 MB plus 15 MB per second of speech in a piece, so up to about
300 MB with pieces of about ten seconds. The Simulator is slower than the
Mac's own command line (its Accelerate may not use the Mac's matrix unit);
the iPhone's figure will come from its diagnostics file.

(Real-time factor: time to make a second of speech; under 1 is faster than
it is spoken.) The app logs each sentence's figure to the diagnostics file
("natural voice: 3.7 s of speech in 507 ms"), so a device's numbers come from
reading a chapter and sharing the file. The minimum device is set for now
by memory (`KokoroVoice.hasMemoryForIt`: 6 GB or more), until measured. (The
rows above the bold ones are the ONNX Runtime version.)

### The voice pack

`scripts/make-kokoro-pack.py` (needs numpy) builds `build/kokoro-pack/` from
pinned, hashed sources (Kokoro's weights converted from hexgrad's checkpoint,
its voices from onnx-community, its symbol table from hexgrad, Misaki's
lexicons from hexgrad/misaki, CMUdict), with their licences and a NOTICE:
103.1 MB unpacked, 81.8 MB zipped (`build/kokoro-pack.zip`, SHA-256 printed;
int8 weights hardly compress). Eight voices: British Emma,
Isabella, George, Lewis; American Heart, Bella, Michael, Fenrir.

### Hosting the voice (decided 23 Nov 2026)

**At launch: a GitHub release, on Mac and iOS alike.** The voice pack
(`build/kokoro-pack.zip`, from `scripts/make-kokoro-pack.py`) is attached to
a release of this repository; the app downloads it only when the reader
agrees (the dialog says what it is and its size; a progress sheet with
Cancel), checks it against a SHA-256 pinned in the app, and refuses it if it
does not match. No other network request; nothing about the reader is sent
(GitHub sees the address the download comes from, as any host would). Every
iOS version the app supports (17 and later) gets the voice, and there is no
App Store Connect step.

Why GitHub: free for release downloads of a public project (files up to
2 GB; 20,000 downloads of 82 MB is about 1.6 TB, ordinary for open-source
projects), versioned with the code, and the same for the direct-download
Mac app. Its risks: GitHub may slow "excessive" use under its terms (no
published limit); some networks block it; it is one company.

**After launch: a second source** (Cloudflare R2, Backblaze B2 or similar),
tried when GitHub fails, checked against the same SHA-256 (README, "After
launch"). Apple-hosted Background Assets (iOS 26.4 and later, an App Store
Connect step) was considered and set aside: it would not reach iOS 17 to
26.3 or the Mac. Its code is still in `KokoroDownload` and can go.

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
  language); `AppleSpeechEngine` speaks with AVSpeechSynthesizer, and
  `KokoroSpeechEngine` with the natural voice: it makes each sentence on a
  background queue, up to two ahead of what is playing, plays them back to
  back through an `AVAudioPlayerNode`, and reports each word as the player
  reaches it.
- **iOS.** The speaker button is in the reader's top bar (Pause and Resume
  while reading; Stop Reading on a long press); `ReadAloudAudio` holds the
  audio session (spoken audio, background playback), the lock screen's Now
  Playing and its controls, and pauses for calls and unplugged headphones.
  Settings › Read Aloud: Apple voice with Play Sample, speed, and where
  better Apple voices come from.
- **PDFs** (23 Nov 2026): see "PDFs" below.
- **Plain text** files open as a made-up book, so they are read as books are.

## Reading on the go (23 Nov 2026, from a day of use on an iPhone)

- **Lock screen and Control Center** (`ReadAloudAudio`): the book's cover
  (the copy Recent Books keeps), title and chapter; play and pause; previous
  and next sentence (`ReadAloudController.skip`). No seek bar and no
  15-second skips: a reading has no set length (`IsLiveStream`).
- **A change of output** (Bluetooth headphones on or off, AirPlay): iOS
  restarts the audio engine and the player's clock starts again, which put
  the natural voice's words out of step with its sound. Now
  `KokoroSpeechEngine` keeps every queued sentence's sound and word times
  and, on `AVAudioEngineConfigurationChange`, plays on from the start of the
  word being read, every later word timed again. (Apple's voices keep their
  own timing.) Debug step `@outputchanged`.
- **Turning the page by hand while reading** (a tap, a swipe, the keys, the
  slider, Contents, Back): once the reader settles (0.6 s), reading starts
  again from the page they are on; if it was paused, it stops, so the
  speaker starts there. Read aloud's own turns do not count
  (`BookSession.onPageMovedByHand`; in PDFs, `movingForReadAloud`).
- **No flash of the whole sentence:** a sentence is underlined whole only
  for a voice that has given no word timing in this reading; before, a
  sentence whose first word came late (after a pause) was underlined whole
  for a moment.
- **"live" said as in "alive", and "a" as the letter:** Misaki tells such
  words apart by word class (verb or adjective), from Apple's tagger, which
  had no English data on the phone (in the Simulator too: "English word
  classes before asking: no"). The natural voice now asks iOS for it when it
  starts (`NLTagger.requestAssets`); the system fetches it. The diagnostics
  file says whether it is available.
- **Battery.** A day's diagnostics: 1.4 hours of speech made in 22 minutes
  of processor time (0.27 of real time). Sampling showed most of that was
  our own loops, not the matrix maths: copying values one at a time for the
  convolutions, and per-sample sines. Done with vDSP and vForce instead, the
  same sound (to within 0.0001) takes 0.13 of real time on the Mac, 2.6
  times less work. Threading made no difference (Accelerate already keeps
  these on one core), and the efficiency cores are too slow (1.8 times real
  time).

## PDFs

The speaker button is in PDFs too (iOS), with the same voices, choice and
lock-screen controls: the button's logic is the base reader's
(`ReaderBaseViewController+ReadAloud.swift`), reading through a
`ReadAloudSource` (a book's `BookSession`, a PDF's `PDFReadAloud`).

- **Text.** PDFKit's page text, read from a second copy of the document on a
  background queue (PDFKit's objects are not for two threads), a batch of
  about 20 sentences at a time, from the page on screen (with the sentence
  that runs onto it from the page before).
- **As a reader would read it** (`PDFReadAloudText`, unit-tested):
  - Running heads and footers are left out: a line among the first or last
    two of a page that recurs, numbers ignored, on at least 30% of the
    pages on the same side within six either way (books often have one head
    on left-hand pages, another on right-hand ones; a chapter's title on its
    first page does not recur, so it is read).
  - Page numbers at the top or bottom ("12", "– 12 –", "Page 3 of 20",
    "xiv") are left out.
  - Lines of nothing but ornaments ("* * *") are left out, and ornaments are
    trimmed from the ends of lines.
  - A word hyphenated at a line's end is joined ("hill-" / "side"); every
    other line or page break is a space, so sentences cross pages whole.
  - A heading in capitals (one line or several) is a sentence of its own.
- **On the page.** Each sentence keeps which parts of which pages it came
  from, so the page turns as the voice reaches it (with the page-turn
  animation for the next page), and each word is underlined with a thin
  accent-coloured underline annotation on the page in memory (never saved:
  Platen does not write PDFs).
- **What it cannot do.** A scanned PDF has no text (nothing is read).
  Footnotes, captions and sidebars are read where the PDF puts them;
  multi-column pages in the order the PDF was made; a drop capital may come
  out as a separate letter ("Asimple").
- **Checked** with the reader's sample PDF (Methods of Rationality, 1,983
  pages: alternating running heads, "* 25*" page numbers, chapter titles of
  several lines) and the fixture `running-heads.pdf` (corpus check
  `@readAloudPreview:`, on the Mac and in the iOS Simulator).

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
- PDFs on the Mac (with the Mac's speaker button); footnotes in PDFs (see
  "PDFs").
- The natural voice: the App Store Connect steps above, and measuring it on
  an iPhone (speed, memory, the first sentence's wait).
