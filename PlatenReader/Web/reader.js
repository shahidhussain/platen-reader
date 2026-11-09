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

import './foliate/view.js'
import { EPUB } from './foliate/epub.js'

// ---------------------------------------------------------------------------
// Bridge to Swift

const post = (type, body = {}) => {
    try {
        window.webkit.messageHandlers.platen.postMessage({ type, ...body })
    } catch {
        // Running in a plain browser for debugging: log instead.
        console.log('[platen →]', type, body)
    }
}

// Forward uncaught errors so they show up in Xcode's console.
window.addEventListener('error', e => post('log', { level: 'error', message: `${e.message} (${e.filename}:${e.lineno})` }))
window.addEventListener('unhandledrejection', e => post('log', { level: 'error', message: String(e.reason?.stack ?? e.reason) }))

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

// ---------------------------------------------------------------------------
// Settings → CSS and layout

let view = null
let settings = null
let isFixedLayout = false

// Approximate characters per line for each line-width setting.
const lineWidthChars = { narrow: 55, medium: 66, wide: 80 }
// Average glyph width as a fraction of font size, for typical book faces.
const charWidthEm = 0.5
// Spec: show two pages when each column can hold about 50 characters.
const minCharsForTwoColumns = 50

const bookCSS = s => `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color-scheme: ${s.theme.dark ? 'dark' : 'light'};
        font-size: ${s.fontSize}px !important;
    }
    html, body {
        background-color: ${s.theme.background} !important;
        color: ${s.theme.foreground} !important;
    }
    a:link, a:visited { color: ${s.theme.link} !important; }
    ${s.lineHeight ? `
    p, li, blockquote, dd, div {
        line-height: ${s.lineHeight} !important;
    }` : ''}
    ${s.fontFamily ? `
    body, p, li, blockquote, dd, td, th, dt, div {
        font-family: "${s.fontFamily.replace(/"/g, '')}", serif !important;
    }
    code, pre, kbd, samp, tt, code *, pre * {
        font-family: ui-monospace, Menlo, monospace !important;
    }` : ''}
    p, li, blockquote, dd {
        -webkit-hyphens: ${s.hyphenate && s.flow === 'paginated' ? 'auto' : 'manual'};
        hyphens: ${s.hyphenate && s.flow === 'paginated' ? 'auto' : 'manual'};
        widows: 2;
        orphans: 2;
    }
    pre { white-space: pre-wrap !important; }
    ${s.theme.dark ? `
    /* Dark line art on transparent backgrounds would vanish; give images a
       light backing so they stay legible. */
    img, svg image { background-color: #f2f2f2; }` : ''}
    /* Footnote bodies are reached by following their links. */
    aside[epub|type~="footnote"], aside[epub|type~="endnote"],
    aside[epub|type~="note"], aside[epub|type~="rearnote"] {
        display: none;
    }
`

const columnCount = s => {
    if (s.flow === 'scrolled') return 1
    if (s.pageLayout === 'one') return 1
    if (s.pageLayout === 'two') return 2
    // Automatic: two pages if each half of the window is wide enough.
    const half = window.innerWidth / 2
    return half >= minCharsForTwoColumns * s.fontSize * charWidthEm * 1.15 ? 2 : 1
}

const applyLayout = () => {
    const r = view?.renderer
    if (!r || !settings) return
    document.documentElement.style.setProperty('--platen-bg', settings.theme.background)
    document.documentElement.style.setProperty('--platen-fg', settings.theme.foreground)
    const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches
    r.toggleAttribute('animated', settings.animated && !reduceMotion)
    if (isFixedLayout) return

    const columns = columnCount(settings)
    const lineWidth = lineWidthChars[settings.lineWidth] * settings.fontSize * charWidthEm
    // In forced two-page mode the columns must fit in the window, whatever
    // the line width setting says.
    const inline = columns === 2 ? Math.min(lineWidth, window.innerWidth / 2) : lineWidth
    r.setAttribute('flow', settings.flow)
    r.setAttribute('max-column-count', columns)
    r.setAttribute('max-inline-size', `${Math.round(inline)}px`)
    r.setAttribute('margin', '44px')
    r.setAttribute('gap', '6%')
    r.setStyles?.(bookCSS(settings))
}

// Debounce re-layout during window resizes so dragging stays smooth; the
// paginator itself keeps the same text anchored in view.
let resizeTimer
window.addEventListener('resize', () => {
    clearTimeout(resizeTimer)
    resizeTimer = setTimeout(applyLayout, 100)
})

// ---------------------------------------------------------------------------
// Pointer input inside book documents

// A "click" is mouse-down and mouse-up with negligible movement. The zone is
// computed in window coordinates and sent to Swift, which decides what to do
// (turn a page or toggle the overlay), so behaviour lives in one place.
const attachPointerHandlers = doc => {
    let down = null
    doc.addEventListener('mousedown', e => {
        const selection = doc.getSelection()
        down = { x: e.screenX, y: e.screenY, hadSelection: selection && !selection.isCollapsed }
    })
    doc.addEventListener('click', e => {
        if (e.button !== 0 || e.detail > 1 || !down) return // part of a double/triple click
        if (down.hadSelection) return // the click just dismissed a selection
        if (Math.hypot(e.screenX - down.x, e.screenY - down.y) > 4) return // a drag
        if (e.target.closest?.('a[href], audio, video, button, input, select, textarea, label')) return
        if (e.defaultPrevented) return

        // Convert from the iframe's coordinates to the window's. The iframe
        // may be scrolled (paginated mode) or scaled (fixed layout).
        const frame = doc.defaultView.frameElement
        const rect = frame.getBoundingClientRect()
        const scale = frame.offsetWidth ? rect.width / frame.offsetWidth : 1
        const x = rect.left + e.clientX * scale
        const third = window.innerWidth / 3
        const zone = x < third ? 'left' : x > 2 * third ? 'right' : 'centre'
        post('click', { zone })
    })
    doc.addEventListener('wheel', onWheel, { passive: false })
    // Context menus are left to WebKit (Look Up, Translate, Copy, Share…).
}

// ---------------------------------------------------------------------------
// Trackpad and scroll wheel (paginated mode)
//
// Horizontal two-finger swipes move the page with the fingers and snap to
// the nearest page on release; vertical wheel movement turns one page per
// gesture. In scroll mode the browser's own scrolling is used unchanged.

const gesture = { axis: null, total: 0, turned: false, timer: null }

function onWheel(e) {
    if (!view || settings?.flow === 'scrolled') return
    e.preventDefault()
    const ax = Math.abs(e.deltaX), ay = Math.abs(e.deltaY)
    if (!gesture.axis) {
        if (ax < 1 && ay < 1) return
        gesture.axis = ax > ay ? 'x' : 'y'
    }
    const r = view.renderer
    if (gesture.axis === 'x' && !isFixedLayout && r.scrollBy) {
        r.scrollBy(e.deltaX, 0)
        gesture.total += e.deltaX
    } else if (!gesture.turned) {
        const delta = gesture.axis === 'x' ? e.deltaX : e.deltaY
        gesture.total += delta
        if (Math.abs(gesture.total) > 24) {
            gesture.turned = true
            const forward = gesture.total > 0
            // Horizontal swipes in fixed layout follow the visual direction.
            if (gesture.axis === 'x') forward ? view.goRight() : view.goLeft()
            else forward ? view.next() : view.prev()
        }
    }
    clearTimeout(gesture.timer)
    // Wheel events have no "fingers lifted" signal in the web, so treat a
    // short pause (after any momentum) as the end of the gesture.
    gesture.timer = setTimeout(endGesture, 90)
}

function endGesture() {
    const r = view?.renderer
    if (gesture.axis === 'x' && !isFixedLayout && r?.snap) {
        // A deliberate swipe (more than 40 px) goes to the next page even if
        // it moved less than half a page; a small nudge springs back.
        const velocity = Math.abs(gesture.total) > 40 ? Math.sign(gesture.total) * 0.5 : 0
        r.snap(velocity, 0)
    }
    gesture.axis = null
    gesture.total = 0
    gesture.turned = false
}

document.addEventListener('wheel', onWheel, { passive: false })

// ---------------------------------------------------------------------------
// Location reporting

const flattenTOC = (items, depth = 0, out = []) => {
    for (const item of items ?? []) {
        out.push({ label: (item.label ?? '').trim(), href: item.href ?? '', depth })
        if (item.subitems?.length) flattenTOC(item.subitems, depth + 1, out)
    }
    return out
}

const metadataString = x => {
    if (!x) return ''
    if (typeof x === 'string') return x
    if (Array.isArray(x)) return x.map(metadataString).filter(Boolean).join(', ')
    if (x.name) return metadataString(x.name)
    const values = Object.values(x)
    return values.length ? metadataString(values[0]) : ''
}

let firstRelocate = true
const onRelocate = ({ detail }) => {
    const { cfi, fraction, tocItem, pageItem, location, section } = detail
    post('relocate', {
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

            view = document.createElement('foliate-view')
            document.body.append(view)
            await view.open(book)
            isFixedLayout = view.isFixedLayout
            settings = options.settings
            view.addEventListener('relocate', onRelocate)
            view.addEventListener('load', ({ detail: { doc } }) => attachPointerHandlers(doc))
            view.addEventListener('external-link', e => {
                // Never navigate the reader; let Swift open it in the browser.
                e.preventDefault()
                post('externalLink', { href: e.detail.a.href })
            })
            view.addEventListener('link', () => post('jumped', { reason: 'link' }))
            applyLayout()

            // Restore the saved position, or start where the main text begins.
            await view.init({ lastLocation: options.lastCFI ?? null, showTextStart: true })

            post('opened', {
                title: metadataString(book.metadata?.title),
                author: metadataString(book.metadata?.author),
                language: metadataString(book.metadata?.language),
                dir: book.dir ?? 'ltr',
                fixedLayout: isFixedLayout,
                toc: flattenTOC(book.toc),
                hasPageList: !!book.pageList?.length,
                sectionFractions: view.getSectionFractions(),
            })
        } catch (e) {
            post('error', { message: String(e?.message ?? e), stack: String(e?.stack ?? '') })
        }
    },
    setSettings(s) {
        settings = s
        applyLayout()
    },
    goLeft: () => view?.goLeft(),
    goRight: () => view?.goRight(),
    next: () => view?.next(),
    prev: () => view?.prev(),
    // Scroll mode: arrow keys move by a fraction of a screen.
    scrollLines: lines => lines > 0 ? view?.next(lines * 40) : view?.prev(-lines * 40),
    nextSection: () => view?.renderer.nextSection?.(),
    prevSection: () => view?.renderer.prevSection?.(),
    goTo: target => view?.goTo(target),
    goToFraction: f => view?.goToFraction(f),
    back: () => view?.history.back(),
    get canGoBack() { return !!view?.history.canGoBack },
}

post('ready')
