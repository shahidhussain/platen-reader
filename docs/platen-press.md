# The platen press and the bookmark ribbon

The app's only two decorative motions: how a book or page arrives on screen, and how a bookmark is laid into it. Everything else in the app stays utilitarian. This is the spec as agreed (25 Nov 2026), followed by how it is built.

## The platen press

### The idea

The app is named after the platen, the glass a page is pressed against in a scanner or photocopier. The screen is that glass, and the reader is underneath it looking up. When a book opens, it is lowered onto the glass from above: it starts small, faint and out of focus, a little crooked, then comes down, sharpens, and one edge touches the glass before the rest settles flat and square. It has to be fast, quiet, and never get in the way of reading.

### When it plays

- **Opening a book** (double-click on Mac, opening from Files, Home or a share on iOS). The animated subject is whatever is shown first: the cover if the book opens at the start, otherwise the page at the saved position.
- **Resuming on launch.** Whenever the app has to show its loading bar before the page appears (a cold start), the saved page presses into place as loading finishes. The loading bar is the only signal; there is no timer.
- **Returning after a long absence** is covered by the rule above: it plays only if the loading bar was needed.

### When it does not play

- Page turns, scrolling, chapter changes, following links, going back.
- Returning to the app when no loading bar is needed: the page shows at once, however long it was away.
- Window resizes, rotation, switching between one and two pages, appearance or typography changes.
- With Reduce Motion on: a plain 150 ms fade from the page colour instead.

### Choreography

About 500 ms when opening a book, about 350 ms when resuming. The start is chosen afresh each time:

- **Opacity** 0, fading in from the page colour (the theme, so light or dark as appropriate).
- **Scale** 0.85: further from the glass.
- **Blur** 12 pt: not yet in focus.
- **Flat turn** 6 to 14 degrees, either way.
- **Tilt** 8 to 12 degrees about an axis in the plane of the screen, with perspective, chosen so the low corner of the flat turn is nearest the glass and lands first.
- **Shadow** wide and soft (30 pt, faint), as it is still in the air.

It ends at opacity 1, scale 1, no blur, turn or tilt, and a tight, nearly invisible shadow: exactly the reading view, so the hand-over has no jump. Opacity finishes by 40% of the way, scale and blur by 70% (it reaches the glass and comes into focus), the flat turn by 85% (it squares up), and the tilt and shadow at 100% (the leading corner has touched; the rest lands flat). The motion is one spring (0.85 damping): a hint of the book settling, with no overshoot to be seen and no second step.

Any click, tap, key or scroll ends it at once, and is then handled as usual. It never delays reading: the book loads and lays out as before, and the press starts from the first page as soon as that is drawn.

## The bookmark ribbon

An orange cloth ribbon hanging from the top edge of the page near its right-hand corner, with a swallowtail notch. It replaces the red one.

- **Look:** the app's orange, as woven grosgrain (fine ribs across it at low contrast), with a line of stitching in a darker thread along both long edges and round the notch. Slightly deeper on dark pages so it does not glow. A very soft shadow on the page beneath it. Slim, and only within the top margin: never over the text.
- **When it shows:** on a bookmarked page while reading, with or without the controls. Turning onto a bookmarked page: simply there. In a spread it hangs from the page that has the bookmark. In Scroll layout it sits level with its line, beside the text where there is room, and scrolls with it.
- **Adding** (the controls, the corner, ⌘D): laid into the book, not slid. Hinged at the page's top edge, it folds down in about 200 ms from nearly end-on (held up towards the reader) to flat, coming in from the page's outer side at about 15 degrees off vertical and straightening as it lands. It slows to a stop as it meets the page (cloth does not stretch: no overshoot, no bounce), then a 1 to 2 degree swing from the top edge dies away within about 150 ms. On iPhone, a light tap as it comes to rest.
- **Removing:** about 150 ms, the same fold in reverse, lifting off and folding up over the top edge, out of sight. No swing.
- **Reduce Motion:** a fade in or out, about 150 ms. Any input during the motion jumps it to its end.

Favourite hearts are orange too, so the app has a single accent colour. The heart (on covers at Home) and the ribbon (in the reader) are never side by side.

## How it is built

- **Numbers:** every timing, angle and amount for both motions is in `PlatenMotion` (`PlatenReader/Shared/PlatenPress.swift`). The web shell gets the ribbon's from there when a book opens (`platen.setRibbonMotion`).
- **The press:** `PlatenPressView` (SwiftUI, both apps) animates a picture of the first page, posed by `PressPose` from one spring-driven progress value; each part's finishing point is a constant. `PressStart.random()` picks the start. Unit tests: `PlatenReaderTests/PlatenPressTests.swift`.
- **The cover:** each `ReaderBaseViewController` (Mac and iOS) puts a plain view in the page colour over the page while it loads, under the controls and the loading bar, so the first page is never seen before it is pressed. When the first page is drawn (`firstPageShown`, called by each reader), it takes a picture of it (`pressPicture`: the web view's snapshot for books, PDFKit's drawing for PDFs), plays the press over the cover, and then takes both away. If the press does not play, or no picture can be had, the cover simply goes. Nothing is loaded or laid out twice.
- **Going back at launch:** on iOS, the launch splash already shows the loading bar while it goes back to a book; the press waits for the splash, which then steps aside quickly as the page lands (`LaunchSplash.follow`). On the Mac, a window put back by macOS's window restoration is a resumption (`BookDocument.restoreState`), pressed only if the spinner showed.
- **The ambient glow (iOS):** the press's background starts in the page colour and turns into the ambient glow by the time the page reaches full size, so page and glow arrive together (the reader asked for this, 25 Nov 2026). The glow is made before the press starts (for a book, after waiting briefly for a cover shown as a native picture, as a page turn does; for a PDF, PDFKit's glow, waited for briefly), and the page's picture is see-through where the page is, over it. After the hand-over the live glow is simply there.
- **Where the ribbon hangs:** on a PDF, from the page's own top edge, never above it (a curl turns only the page, so a ribbon reaching above it showed its top before the rest curled in). In a book on iOS, from the very top of the screen, far enough in from its right-hand edge to clear the screen's rounded corner (about 60 points on a phone, 26 on an iPad; `ReaderViewController.ribbonInset`) (in a spread, from the top right of each page's half): a place tied to the page rather than to where the text happens to start, at the cost of sometimes sitting under the status bar's battery while the controls are up (device testing, 25 Nov 2026). On the Mac, just below the title bar, whose strip takes clicks to move the window. In Scroll layout, beside its line.
- **Size and the controls (iOS):** the ribbon is half as big again as its 20 by 30 points (30 by 45), to be seen at a glance. While the controls are up, their top bar would cover it, so it stands just below the bar (past its band's fade), twice its size (40 by 60) and 16 points in from the edge, and slides back to its place when they go (the reader's request, 25 Nov 2026). Adding a bookmark from the controls lays it down there. The pictures are drawn at twice the density their names say, so it stays sharp at these sizes.
- **The ribbon's picture** is a drawn picture (`design/ribbon/make-ribbon.swift` → `PlatenReader/Web/ribbon/`, 2x and 3x, light and dark). In books, `bookmarks.js` shows and moves it (Web Animations); on iOS PDFs, `BookmarkRibbonView` (Core Animation) does the same from the same pictures.
- **iOS presentation:** the reader now fades in rather than sliding up, so the press is the book's one arrival motion.

## Not done yet

- The Mac's PDF reader still has no ribbon (it never had one).
- The optional second phase, a Metal shader so the leading edge comes into focus before the far one, waits until the uniform blur has been seen on devices.
- The checks the spec asks for on real hardware: covers that are light, dark, very tall and very wide; a text page in light and dark; no dropped frames on an older device and on a Mac with a large window; Reduce Motion and quick app switching.
