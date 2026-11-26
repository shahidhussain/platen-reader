// Platen Reader: the JavaScript side of the reader view.
//
// Swift owns files, parsing and state; this file only drives foliate-js.
// It talks to Swift in two directions:
//
//   Swift → JS: calls `window.platen.<command>(...)` via evaluateJavaScript.
//   JS → Swift: `post(type, body)` → WKScriptMessageHandler named "platen".
//
// Book files are fetched from /book/<path> on the same origin, which the
// Swift URL scheme handler serves from memory. Nothing here touches the
// network or the file system.
//
// This file opens the book and holds the `platen` commands; the rest lives
// in modules/:
//   state.js        what the modules share (the foliate view, settings)
//   bridge.js       post() to Swift
//   layout.js       settings → book CSS and page layout
//   bookfixes.js    unreadable colours, publisher font sizes, wide tables
//   input.js        clicks, pictures, selection, trackpad swipes
//   pagenumbers.js  numbers under each page
//   bookmarks.js    ribbons and bookmarking
//   jumps.js        jumps and the Back button
//   search.js       find in book
//   contents.js     table of contents
//   accessibility.js  VoiceOver: names, and reading each page aloud
//   footnotes.js    notes in a pop-up instead of a jump

import './foliate/view.js'
import { EPUB } from './foliate/epub.js'
import { reader } from './modules/state.js'
import { applyJustification, auditColours, ensureReadableColours, fitLonePicture, fitOverflowingPictures, fitWideTables, normaliseBodyTextSize, overflowingPictures, rescalePublisherFontSizes } from './modules/bookfixes.js'
import { pagesOnScreen, scheduleRibbons, setBookmarkList, setControlsVisible as ribbonsWithControls, setRibbonMotion, toggleBookmark } from './modules/bookmarks.js'
import { post } from './modules/bridge.js'
import { sendContents } from './modules/contents.js'
import { attachPointerHandlers, noteScroll, pictureAt, swipe, tapTarget } from './modules/input.js'
import { goBack, jump, noteMovement, rememberJumpOrigin } from './modules/jumps.js'
import { applyLayout, measureText, shownFontSize } from './modules/layout.js'
import { nameBook, nameSection, pageChanged, readPage, setVoiceOver } from './modules/accessibility.js'
import { followScroll, updatePageNumbers } from './modules/pagenumbers.js'
import { clearSearch, search } from './modules/search.js'
import { closeNote, handleNoteLink } from './modules/footnotes.js'
import { readAloud } from './modules/readaloud.js'

// ---------------------------------------------------------------------------
// Loading book files from Swift

// Each path segment is encoded so names with spaces, '#', '?' or non-ASCII
// characters survive the trip. Swift decodes exactly once on the other side.
const bookURL = path => '/book/' + path.split('/').map(encodeURIComponent).join('/')

// The loader interface foliate-js's EPUB class expects (see its README).
const makeLoader = sizes => ({
    loadText: async name => {
        const res = await fetch(bookURL(name))
        return res.ok ? res.text() : null
    },
    loadBlob: async (name, type) => {
        const res = await fetch(bookURL(name))
        if (!res.ok) return null
        const blob = await res.blob()
        return type && blob.type !== type ? new Blob([blob], { type }) : blob
    },
    getSize: name => sizes?.[name] ?? 0,
})

const openBook = async ({ format, sizes }) => {
    if (format === 'mobi') {
        // MOBI/AZW/AZW3: foliate-js parses the whole file itself.
        const blob = await (await fetch(bookURL('__file__'))).blob()
        const { MOBI } = await import('./foliate/mobi.js')
        const fflate = await import('./foliate/vendor/fflate.js')
        return new MOBI({ unzlib: fflate.unzlibSync }).open(blob)
    }
    return new EPUB(makeLoader(sizes)).init()
}

const metadataString = x => {
    if (!x) return ''
    if (typeof x === 'string') return x
    if (Array.isArray(x)) return x.map(metadataString).filter(Boolean).join(', ')
    if (x.name) return metadataString(x.name)
    const values = Object.values(x)
    return values.length ? metadataString(values[0]) : ''
}


// ---------------------------------------------------------------------------
// Location reporting

// "The first page is visible" is told to Swift once both of these have
// happened: the first chapter's frame has loaded, and foliate has reported
// where the reader is. (foliate's first report can come before the frame
// has loaded, while the page is still blank; on iOS the gap can be seconds.)
let hasRelocated = false
let hasLoadedSection = false
let firstRenderSent = false
const sendFirstRender = force => {
    if (firstRenderSent || !(force || (hasRelocated && hasLoadedSection))) return
    firstRenderSent = true
    post('firstRender')
}
// iOS: a page that is just one picture is shown natively, as large as the
// screen allows. That is a whole chapter that is one picture (bookfixes.js
// marks those), or any single page, anywhere in a chapter, on which one
// picture is all there is (a plate between pages of text). Its bytes go to
// Swift once per picture; an empty message says the page on screen no
// longer is one. Only with one page across, in paginated mode, and not in
// fixed layout books (whose pages are drawn as the publisher made them).
//
// The picture being shown (a key: chapter and picture), and the one Swift
// has (sent, not just being read).
let lonePictureKey = null
let lonePictureSent = null
// The page's own copy, hidden while the native one shows.
let hiddenPicture = null

// The one picture on the page on screen, if that is all the page holds.
// foliate's visible range only takes in elements wholly on the page, so on
// such a page it holds that picture and (almost) no text. Small pictures
// (ornaments, a drop cap drawn as an image) do not count.
function pagePicture(doc) {
    const range = reader.view?.lastLocation?.range
    if (!range || range.startContainer?.ownerDocument !== doc) return null
    if (range.toString().replace(/\s+/g, '').length > 20) return null
    const pictures = [...doc.querySelectorAll('img, svg')].filter(p => {
        if (p.localName === 'img' ? p.closest('svg') : p.parentElement?.closest('svg')) return false
        if (!range.intersectsNode(p)) return false
        const { width, height } = p.getBoundingClientRect()
        return width >= 120 && height >= 120
    })
    return pictures.length === 1 ? pictures[0] : null
}

// The picture-only page on screen, if there is one (and native display is
// in use: one page across, paginated, not fixed layout, on iOS). `picture`
// is the img or svg element; `key` names it within the book.
function currentLonePicture() {
    const r = reader.view?.renderer
    const { doc, index } = r?.getContents?.()[0] ?? {}
    const usable = reader.settings?.touch && !reader.isFixedLayout && reader.settings?.flow !== 'scrolled'
        && (r?.feet?.length ?? 1) === 1
    if (!usable || !doc) return { r, doc, index, picture: null, key: null }
    const picture = doc.documentElement.classList.contains('platen-lone-picture')
        ? doc.querySelector('img, svg') : pagePicture(doc)
    const key = picture ? `${index}:${[...doc.querySelectorAll('img, svg')].indexOf(picture)}` : null
    return { r, doc, index, picture, key }
}
// The address of a picture's bytes (an svg's is in its <image>).
function pictureSource(picture) {
    if (picture.localName === 'img') return picture.currentSrc || picture.src
    const image = picture.querySelector('image')
    return image?.getAttribute('href') ?? image?.getAttributeNS('http://www.w3.org/1999/xlink', 'href')
}
function showPageCopy() {
    hiddenPicture?.style.removeProperty('visibility')
    hiddenPicture = null
}
// For a page turn, before it is drawn: whether the page now on screen is a
// picture-only page whose picture Swift already has ('same'), one it is
// about to be sent ('new'), or not one ('none').
function lonePictureState() {
    const { picture, key } = currentLonePicture()
    if (!picture) return 'none'
    return lonePictureSent === key ? 'same' : 'new'
}
async function reportLonePicture() {
    const { picture, key } = currentLonePicture()
    if (!picture) {
        if (lonePictureKey !== null) {
            lonePictureKey = null
            lonePictureSent = null
            post('lonePicture', {})
            // The page's own copy shows again (Scroll, two pages…).
            showPageCopy()
        }
        return
    }
    if (lonePictureKey === key) return
    lonePictureKey = key
    try {
        const src = pictureSource(picture)
        if (!src) throw new Error('no source')
        const blob = await (await fetch(src)).blob()
        const bytes = new Uint8Array(await blob.arrayBuffer())
        let binary = ''
        for (let i = 0; i < bytes.length; i += 0x8000)
            binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
        if (lonePictureKey !== key) return // moved on meanwhile
        post('lonePicture', { data: btoa(binary), mimeType: blob.type })
        lonePictureSent = key
        showPageCopy()
        picture.style.setProperty('visibility', 'hidden', 'important')
        hiddenPicture = picture
    } catch (e) {
        lonePictureKey = null
        post('log', { level: 'error', message: `lone picture: ${e}` })
    }
}

let lastReason = null
const onRelocate = ({ detail }) => {
    const { cfi, fraction, tocItem, pageItem, location, section } = detail
    const r = reader.view.renderer
    const pagesLeft = !reader.isFixedLayout && reader.settings?.flow !== 'scrolled' && r.pages > 0
        ? Math.max(0, r.pages - 2 - r.page) : null
    // foliate reports *why* the view moved on the renderer's event, which
    // fires after this one; read it once the current dispatch has finished.
    queueMicrotask(() => {
        noteMovement(lastReason)
        scheduleRibbons()
        updatePageNumbers(detail)
        // Keep the frame's name on the chapter being read (for VoiceOver).
        for (const { doc } of reader.view.renderer.getContents?.() ?? []) nameSection(doc, tocItem?.label?.trim())
        pageChanged(lastReason)
        reportLonePicture()
        // Page width changes with the layout; re-check tables and pictures
        // each time.
        if (!reader.isFixedLayout && reader.settings?.flow !== 'scrolled')
            for (const { doc } of reader.view.renderer.getContents?.() ?? []) if (doc) {
                fitWideTables(doc)
                fitOverflowingPictures(doc)
            }
    })
    post('relocate', {
        pagesLeft,
        // Pages side by side (Two Pages falls back to one in a narrow window).
        columns: r.feet?.length ?? 1,
        chapterHref: tocItem?.href ?? null,
        cfi,
        fraction: fraction ?? 0,
        chapter: tocItem?.label?.trim() ?? '',
        page: pageItem?.label ?? null,
        section: section?.current ?? null,
        location: location?.current ?? null,
        totalLocations: location?.total ?? null,
    })
    if (!hasRelocated) {
        hasRelocated = true
        sendFirstRender()
        // A section that cannot be loaded (a damaged book) never reports a
        // load; do not wait for it for ever.
        setTimeout(() => sendFirstRender(true), 3000)
    }
}

// ---------------------------------------------------------------------------
// Commands from Swift

window.platen = {
    async open(options) {
        try {
            const book = await openBook(options)
            // A damaged section should show as empty, not stop the book.
            book.transformTarget?.addEventListener('data', ({ detail }) => {
                detail.data = Promise.resolve(detail.data).catch(e => {
                    post('log', { level: 'error', message: `Failed to load ${detail.name}: ${e}` })
                    return ''
                })
            })

            reader.view = document.createElement('foliate-view')
            document.body.append(reader.view)
            await reader.view.open(book)
            // Named now, before the first chapter loads (its frame takes the name).
            nameBook(metadataString(book.metadata?.title))
            reader.isFixedLayout = reader.view.isFixedLayout
            reader.settings = options.settings
            reader.view.addEventListener('relocate', onRelocate)
            reader.view.addEventListener('load', ({ detail: { doc, index } }) => {
                if (!reader.isFixedLayout) {
                    rescalePublisherFontSizes(doc)
                    ensureReadableColours(doc)
                    // And again a moment later, for styles that arrive
                    // after the page (imported style sheets, say).
                    setTimeout(() => ensureReadableColours(doc), 600)
                    // Body text at the size chosen, whatever the book's CSS.
                    normaliseBodyTextSize(doc, shownFontSize())
                    // A page that is one picture, as large as the page.
                    fitLonePicture(doc)
                    // Ragged right, if Justify Text is off.
                    applyJustification(doc, reader.settings?.justify !== false)
                }
                attachPointerHandlers(doc, index)
                nameSection(doc, reader.view.getProgressOf?.(index)?.tocItem?.label?.trim())
                hasLoadedSection = true
                sendFirstRender()
            })
            reader.view.renderer.addEventListener('relocate', e => { lastReason = e.detail.reason })
            reader.view.renderer.addEventListener('scroll', followScroll)
            // A tap just after scrolling stopped a flick (input.js).
            reader.view.renderer.addEventListener('scroll', noteScroll, { passive: true })
            reader.view.addEventListener('external-link', e => {
                // Never navigate the reader; let Swift open it in the browser.
                e.preventDefault()
                post('externalLink', { href: e.detail.a.href })
            })
            // Following a link is a jump: offer a way back.
            // Note references show their note in a pop-up instead of going
            // there (footnotes.js); any other link is a jump.
            reader.view.addEventListener('link', e => { if (!handleNoteLink(e)) rememberJumpOrigin() })
            applyLayout()

            // Restore the saved position, or start where the main text begins.
            await reader.view.init({ lastLocation: options.lastCFI ?? null, showTextStart: true })

            post('opened', {
                title: metadataString(book.metadata?.title),
                author: metadataString(book.metadata?.author),
                language: metadataString(book.metadata?.language),
                dir: book.dir ?? 'ltr',
                fixedLayout: reader.isFixedLayout,
                hasPageList: !!book.pageList?.length,
                sectionFractions: reader.view.getSectionFractions(),
            })
            // Contents and chapter labels are worked out after the first page
            // is on screen, so they never delay opening.
            setTimeout(() => sendContents(book), 0)
        } catch (e) {
            post('error', { message: String(e?.message ?? e), stack: String(e?.stack ?? '') })
        }
    },
    setSettings(s) {
        const themeChanged = s.theme?.background !== reader.settings?.theme?.background
        reader.settings = s
        applyLayout()
        if (themeChanged && !reader.isFixedLayout)
            for (const { doc } of reader.view?.renderer?.getContents?.() ?? []) ensureReadableColours(doc)
    },
    goLeft: () => reader.view?.goLeft(),
    goRight: () => reader.view?.goRight(),
    next: () => reader.view?.next(),
    prev: () => reader.view?.prev(),
    // Scroll mode: arrow keys move by a fraction of a screen.
    scrollLines: lines => lines > 0 ? reader.view?.next(lines * 40) : reader.view?.prev(-lines * 40),
    nextSection: () => reader.view?.renderer.nextSection?.(),
    prevSection: () => reader.view?.renderer.prevSection?.(),
    // Jumps (contents, bookmarks, search results, slider) remember where
    // the reader came from, for the Back button.
    // `keepOrigin`: stepping through search results keeps "Back" pointing
    // at where the reader was before the first result.
    jumpTo: (target, keepOrigin) => jump(() => reader.view.goTo(target), keepOrigin),
    jumpToFraction: f => jump(() => reader.view.goToFraction(f)),
    goBack,
    setBookmarks: setBookmarkList,
    setRibbonMotion,
    toggleBookmark,
    search,
    // For the page-turn animation (drawn natively from snapshots): turn
    // with no slide, and resolve once the new page has been painted. Says
    // whether the page changed and how many pages are side by side.
    async turnInstantly(direction) {
        if (!reader.view) return { moved: false, columns: 1 }
        const r = reader.view.renderer
        // At the very start or end there is nowhere to go: say so at once,
        // rather than waiting for a page change that will not come.
        const rtl = reader.view.book.dir === 'rtl'
        // Forward in reading order: next, or the side the book reads towards.
        const forward = direction === 'next'
            || (direction === 'right' && !rtl) || (direction === 'left' && rtl)
        if (forward ? r.atEnd : r.atStart) return { moved: false, columns: 1 }
        const before = reader.view.lastLocation?.cfi
        const animated = r.hasAttribute('animated')
        r.removeAttribute('animated')
        const relocated = new Promise(resolve => {
            const timer = setTimeout(resolve, 400) // at the start or end of the book
            reader.view.addEventListener('relocate', () => { clearTimeout(timer); resolve() }, { once: true })
        })
        ;({ left: () => reader.view.goLeft(), right: () => reader.view.goRight(),
            next: () => reader.view.next(), prev: () => reader.view.prev() })[direction]?.()
        await relocated
        if (animated) r.setAttribute('animated', '')
        // Two frames: the first lays out, the second is on screen.
        await new Promise(requestAnimationFrame)
        await new Promise(requestAnimationFrame)
        const columns = reader.isFixedLayout ? Math.max(1, pagesOnScreen().length) : (r.feet?.length ?? 1)
        return { moved: reader.view.lastLocation?.cfi !== before, columns }
    },
    // VoiceOver on or off (from Swift, which watches the system setting).
    setVoiceOver,
    readPage,
    swipeMove: dx => swipe.move(dx),
    swipeEnd: direction => swipe.end(direction),
    // iOS: what is under a tap (see tapTarget in input.js).
    tapTarget,
    // Testing: text still too faint to read against the page (bookfixes.js).
    auditColours,
    // iOS: where a fixed-layout book's pages are on screen, [x, y, width,
    // height] each in window coordinates (blank halves of a spread left
    // out), so the ambient glow is made from the pages alone.
    pageRects: () => (reader.view?.renderer?.getContents?.() ?? [])
        .map(({ doc }) => doc?.defaultView?.frameElement?.getBoundingClientRect())
        .filter(r => r && r.width > 1 && r.height > 1 && r.right > 0 && r.left < innerWidth
            && r.bottom > 0 && r.top < innerHeight)
        .map(r => [r.left, r.top, r.width, r.height]),
    // iOS: the picture under a held finger, sent as an 'image' message.
    pictureAt,
    // iOS, during a page turn: is the new page a picture-only page?
    lonePictureState,
    // Whether the page on screen is one picture and nothing else, whatever
    // the platform (the corpus checks it on the Mac, which has no native
    // picture view).
    pagePicture: () => {
        const doc = reader.view?.renderer?.getContents?.()[0]?.doc
        return !!(doc && pagePicture(doc))
    },
    // The text size chosen, in pixels (for checks: body text should be it).
    fontSize: () => shownFontSize(),
    // Esc closes an open note pop-up; says whether there was one.
    closeNote,
    // iOS: the controls are up (or not). Their location line covers the
    // page number, so the page number steps aside meanwhile.
    // Read aloud (modules/readaloud.js): Swift speaks, this supplies text.
    readAloudStart: () => readAloud.start(),
    readAloudMore: () => readAloud.more(),
    readAloudMark: name => readAloud.mark(name),
    readAloudWord: (name, start, length) => readAloud.word(name, start, length),
    readAloudStop: () => readAloud.stop(),
    readAloudHold: () => readAloud.hold(),
    readAloudPreview: () => readAloud.preview(),
    readAloudSentences: count => readAloud.sentences(count),
    readAloudProbeStart: () => readAloud.probeStart(),
    measureText,
    // How many pictures on the chapters laid out reach past their page's
    // right-hand edge (none should: fitOverflowingPictures).
    pictureOverflow: () => (reader.view?.renderer.getContents?.() ?? [])
        .reduce((n, { doc }) => n + (doc ? overflowingPictures(doc) : 0), 0),
    setControlsVisible: (on, headerBottom) => {
        document.getElementById('page-numbers')?.classList.toggle('under-controls', !!on)
        ribbonsWithControls(on, headerBottom)
    },
    // For debugging and automated checks (scripts/run-debug.sh steps).
    get view() { return reader.view },
    clearSearch,
}

post('ready')
