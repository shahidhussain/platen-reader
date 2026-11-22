# Read aloud

The speaker button reads the book aloud from the current page, highlighting
the sentence being read and turning pages as it goes. English books can use
the Kokoro-82M neural voice once the reader has downloaded it; every other
language, and readers who do not download it, use Apple's voices. iOS first;
the Mac follows with the same shared code. The decisions are in the spec
("Decisions made": Read aloud, Voice download).

## Step 0: licences and runtime (22 Nov 2026)

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

**Choice: vendored KokoroAne (Core ML).** Recorded 22 Nov 2026.

### Hosting the voice

- **iOS:** Apple-hosted Background Assets (an asset pack uploaded with the
  build in App Store Connect). Apple-hosted packs need **iOS 26** or later.
  The app supports iOS 17, so on iOS 17 to 25 the Kokoro voice is not
  offered: English books read with Apple's voices, with no first-tap
  dialog, and Settings shows only Apple's voices. Uploading the asset pack
  is a step in App Store Connect (see "Still to do").
- **Mac (direct download):** a GitHub release asset, checked against a
  SHA-256 pinned in the app before it is used. No other network call.

### Measurements

To fill in on the oldest supported iPhone once the Kokoro engine runs:
time to first audio, real-time factor, peak memory, battery per hour. The
minimum device for Kokoro is set from these; below it, only Apple's voices
are offered.

| Device | First audio | Real-time factor | Peak memory | Battery / hour |
| --- | --- | --- | --- | --- |
| (to measure) | | | | |

## How it works

- **Text and marks (the shell).** foliate's `tts.js` (vendored at the pinned
  commit) splits each section into blocks and sentences and marks each
  sentence. `modules/readaloud.js` sends Swift a block at a time (its
  language and sentences), starting from the first sentence on the current
  page, and highlights the sentence Swift says is being spoken (the CSS
  Highlight API, so the page is not changed), turning the page to it.
- **Speech (Swift, Shared).** `ReadAloud` holds the queue of sentences and
  a `SpeechEngine`: `AppleSpeechEngine` (AVSpeechSynthesizer) or the Kokoro
  engine, chosen by `SpeechEngineChooser` from the book's language, the
  reader's choice and whether the voice is installed. Sentences are spoken
  in order; Kokoro synthesises one or two sentences ahead of playback.
- **iOS.** The speaker button is in the reader's controls; the audio session
  (spoken audio, background playback), the lock screen's Now Playing and
  its remote commands, and pausing for calls and when headphones are
  unplugged are in the app's `+UIKit` files.
- **PDFs.** Not read aloud yet: the speaker button is only in books. PDFKit's page text, without highlighting, is the plan; it needs its own feeder in place of readaloud.js.

## What is stored

- The chosen engine (Kokoro or Apple), the voice for each, and the speed:
  global settings, like every other setting.
- The Kokoro voice pack: in the app's own storage (iOS: managed by
  Background Assets; Mac: Application Support), removable in Settings ›
  Read Aloud. Nothing is stored per book.

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

- The Kokoro engine and the voice download (vendoring KokoroAne's English
  parts, the asset pack, the Mac download), and the measurements above.
- Uploading the asset pack in App Store Connect (yours: it is tied to the
  app record).
- The Mac's speaker button and Settings.
- PDFs (PDFKit's page text, no highlighting).
- Checking reading at the lock screen on a device, and how long the
  text read ahead lasts there (the Simulator cannot lock).
