# App Store screenshots

One command makes the iOS App Store screenshots from the app itself:

```sh
marketing/screenshots/build.sh                 # build, capture, compose (about 10 minutes)
marketing/screenshots/build.sh --compose-only  # captions and frames only (half a minute)
```

The results are in `build/final/<en-GB|en-US>/<iphone|ipad>/` at App Store Connect's sizes (1320 × 2868 for the 6.9-inch iPhone, 2064 × 2752 for the 13-inch iPad), without transparency, and side by side in `build/contact-sheet.html`. `build/` is not committed.

## How it works

1. **Capture** (`capture.py`). Two simulators of its own, "Platen Screenshots iPhone" and "Platen Screenshots iPad" (made if missing, erased at every run, shut down at the end; the simulators used day to day are never touched). The sample books are copied into the app as the folders in `library.json`, and read aloud's natural voice from `build/kokoro-pack` (`scripts/make-kokoro-pack.py`), so nothing is downloaded. Each scene is set up through the Debug build's own hooks (`PlatenReader iOS/Sources/DebugHooks.swift`): `PLATEN_FOLDER_PATH`, `PLATEN_ADD_FAVOURITES`, `PLATEN_OPEN_PATH` and the `PLATEN_STEPS` steps for theme, layout, turning sideways, ambient light, the controls and read aloud. The script waits for the app's `@shot:ready` picture and then saves the whole screen with `simctl`, status bar included (9:41, full signal and battery).
   - On the iPad, the installed copy is marked full screen (`UIRequiresFullScreen`), as iPadOS lets only a full-screen app turn itself sideways; the window's resize handle is painted over. Neither changes how Platen looks.
2. **Compose** (`compose.py`, `render.swift`). Each picture is an HTML page (caption, framed screenshot, background from `palette.json`) drawn by WebKit and saved at the exact size. The captions are set in IBM Plex Sans, as the website's headings are (`fonts/`, from github.com/IBM/plex, SIL Open Font License: `fonts/OFL.txt`).

## Scenes

Each folder in `scenes/` is one screenshot, in order. Its `scene.md` has one `key: value` per line:

| Key | Meaning |
|---|---|
| `headline`, `subheading` | The caption (en-GB). `subheading_ipad`, `headline_en_US`, `subheading_en_US` (and `…_ipad_en_US`) override it for a device or the US storefront |
| `show` | `home`, `book` or `none` (a card with the icon and caption only) |
| `favourites` | (`home`) books marked as favourites, the first shown first, separated by `\|` |
| `book` | (`book`) the book, as `<folder>/<file>` from `library.json` |
| `location` | A fraction of the book (`0.3`), or `page N` for a PDF |
| `theme` | `light`, `sepia`, `dark` or `black` |
| `orientation` | `portrait` or `landscape` |
| `before` | `portrait`: also a picture of the page upright, just before turning sideways; the card then shows both |
| `layout`, `ambient`, `controls`, `readaloud` | `one`/`two`/`scroll`, `on`/`off`, `show`/`hide`, `on`/`off` |
| `listen` | With read aloud: how many 1.5-second steps to let it read first |
| `background` | Overrides the palette's top colour |

## Which books may be shown

The screenshots are seen worldwide, so a book shown open must be public domain everywhere or licensed for it; see `credits.md`. `library.json` lists only books that may appear, and the sample library itself (`marketing/sample-library`) is not committed.

## Still to add

- **Device frames:** a drawn frame stands in for Apple's. If you prefer Apple's own, download from Apple Design Resources (Product Bezels) the iPhone 17 Pro Max (or newer) portrait PNG and the iPad Pro 13-inch (M5 or M4) portrait and landscape PNGs into `bezels/`.

## Later

- Mac screenshots at 16:10 (the Mac's `scripts/run-debug.sh` has its own hooks).
- An App Store preview video, recorded from the same scenes with `simctl io recordVideo`.

## Header and search results picture

`python3 make-header.py` (after `build.sh`) makes the product page header for iOS and iPadOS 27: `build/header/header.png`, 5244 × 2950, flat RGB. It shows the icon, "Platen Reader" and a phrase on dark brown, beside an iPad reading Zoe and Zephy (captured first with `capture.py --device ipad --scenes header-scenes`), with everything in the area both App Store crops keep (21:9 header, 3:2 search). `preview-21x9.png` and `preview-3x2.png` show each crop with that area outlined in red.
