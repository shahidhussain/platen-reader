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
//   accessibility.js  names and page-following for VoiceOver

import './foliate/view.js'
import { EPUB } from './foliate/epub.js'
import { reader } from './modules/state.js'
import { ensureReadableColours, fitWideTables, rescalePublisherFontSizes } from './modules/bookfixes.js'
import { pagesOnScreen, scheduleRibbons, setBookmarkList, toggleBookmark } from './modules/bookmarks.js'
import { post } from './modules/bridge.js'
import { sendContents } from './modules/contents.js'
import { attachPointerHandlers, swipe } from './modules/input.js'
import { goBack, jump, noteMovement, rememberJumpOrigin } from './modules/jumps.js'
import { applyLayout } from './modules/layout.js'
import { followPage, nameBook, nameSection, setVoiceOver } from './modules/accessibility.js'
import { followScroll, updatePageNumbers } from './modules/pagenumbers.js'
import { clearSearch, search } from './modules/search.js'

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

let firstRelocate = true
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
        followPage()
        // Page width changes with the layout; re-check tables each time.
        if (!reader.isFixedLayout && reader.settings?.flow !== 'scrolled')
            for (const { doc } of reader.view.renderer.getContents?.() ?? []) if (doc) fitWideTables(doc)
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
    if (firstRelocate) {
        firstRelocate = false
        post('firstRender')
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
                }
                attachPointerHandlers(doc, index)
                nameSection(doc, reader.view.getProgressOf?.(index)?.tocItem?.label?.trim())
            })
            reader.view.renderer.addEventListener('relocate', e => { lastReason = e.detail.reason })
            reader.view.renderer.addEventListener('scroll', followScroll)
            reader.view.addEventListener('external-link', e => {
                // Never navigate the reader; let Swift open it in the browser.
                e.preventDefault()
                post('externalLink', { href: e.detail.a.href })
            })
            // Following a link is a jump: offer a way back.
            reader.view.addEventListener('link', () => rememberJumpOrigin())
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
    toggleBookmark,
    search,
    // For the page-turn animation (drawn natively from snapshots): turn
    // with no slide, and resolve once the new page has been painted. Says
    // whether the page changed and how many pages are side by side.
    async turnInstantly(direction) {
        if (!reader.view) return { moved: false, columns: 1 }
        const r = reader.view.renderer
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
    swipeMove: dx => swipe.move(dx),
    swipeEnd: direction => swipe.end(direction),
    // For debugging and automated checks (scripts/run-debug.sh steps).
    get view() { return reader.view },
    clearSearch,
}

post('ready')
