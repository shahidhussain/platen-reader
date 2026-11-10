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
import { Overlayer } from './foliate/overlayer.js'

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
// Narrow is a classic book measure; Wide lets text run much closer to the
// edges of a large window.
const lineWidthChars = { narrow: 66, medium: 80, wide: 120 }
// With two pages side by side: how much of each half of the window a page
// may use (the rest is margin and the gap at the spine).
const twoPageShare = { narrow: 0.72, medium: 0.86, wide: 1 }
// Average glyph width as a fraction of font size, for typical book faces.
const charWidthEm = 0.5
// Spec: show two pages when each column can hold about 50 characters.
const minCharsForTwoColumns = 50

const bookCSS = s => `
    /* platen-styles (reader.js skips this sheet when rescaling font sizes) */
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
    /* Nothing may be wider than a page: in paginated mode anything wider
       spills into the next column and is drawn over its text. */
    body * { max-width: 100% !important; box-sizing: border-box; }
    body { overflow-wrap: break-word; }
    img, svg, video, table { height: auto; }
    ${s.theme.dark ? `
    /* Dark line art on transparent backgrounds would vanish; give images a
       light backing so they stay legible. */
    img, svg image { background-color: #f2f2f2; }` : ''}
    /* Kobo KEPUBs wrap the whole book in fixed-size column containers meant
       for Kobo's own reader; they fight our pagination, so neutralise them. */
    div#book-columns, div#book-inner {
        column-count: auto !important; columns: auto !important;
        width: auto !important; height: auto !important;
        margin: 0 !important; padding: 0 !important;
        overflow: visible !important;
    }
    /* Footnote bodies are reached by following their links. */
    aside[epub|type~="footnote"], aside[epub|type~="endnote"],
    aside[epub|type~="note"], aside[epub|type~="rearnote"] {
        display: none;
    }
`

const columnCount = s => {
    if (s.flow === 'scrolled') return 1
    if (s.pageLayout === 'one') return 1
    // Two pages, side by side when each half of the window can hold a
    // readable line; a narrow window falls back to one page.
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
    // Two pages: each page gets a share of half the window, so the three
    // widths stay distinct even when the character counts would all be
    // wider than the half (they still cap it on very large screens).
    const inline = columns === 2
        ? Math.min(lineWidth, window.innerWidth / 2 * twoPageShare[settings.lineWidth])
        : lineWidth
    r.setAttribute('flow', settings.flow)
    r.setAttribute('max-column-count', columns)
    r.setAttribute('max-inline-size', `${Math.round(inline)}px`)
    // In paginated mode the top margin leaves room for the bookmark ribbon
    // below the (hidden) title bar.
    r.setAttribute('margin', settings.flow === 'scrolled' ? '44px' : '60px')
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
//
// The side zones are wider than the centre: most clicks are page turns.
const sideZoneFraction = 0.38

// A press held this long is a long press or a Force Touch (Look Up), not a
// click: acting on it would dismiss the Look Up panel it opened.
const longPressMs = 450

// Images smaller than this (icons, ornaments, drop caps) are not zoomable.
const minZoomableSize = 48

const attachPointerHandlers = (doc, index) => {
    let down = null
    doc.addEventListener('mousedown', e => {
        const selection = doc.getSelection()
        down = { x: e.screenX, y: e.screenY, t: e.timeStamp, forced: false,
                 hadSelection: selection && !selection.isCollapsed }
    })
    // WebKit's Force Touch events: a firm press opens Look Up.
    for (const type of ['webkitmouseforcewillbegin', 'webkitmouseforcedown'])
        doc.addEventListener(type, () => { if (down) down.forced = true })
    doc.addEventListener('click', e => {
        if (e.button !== 0 || e.detail > 1 || !down) return // part of a double/triple click
        if (down.hadSelection) return // the click just dismissed a selection
        if (down.forced || e.timeStamp - down.t > longPressMs) return
        if (Math.hypot(e.screenX - down.x, e.screenY - down.y) > 4) return // a drag
        if (e.target.closest?.('a[href], audio, video, button, input, select, textarea, label')) return
        if (e.defaultPrevented) return

        // Convert from the iframe's coordinates to the window's. The iframe
        // may be scrolled (paginated mode) or scaled (fixed layout).
        const frame = doc.defaultView.frameElement
        const rect = frame.getBoundingClientRect()
        const scale = frame.offsetWidth ? rect.width / frame.offsetWidth : 1

        // A click on a picture opens it full size (not in fixed layout, where
        // the whole page is usually one picture).
        const img = !isFixedLayout && e.target.closest?.('img')
        if (img) {
            const r = img.getBoundingClientRect()
            if (r.width * scale >= minZoomableSize && r.height * scale >= minZoomableSize) {
                zoomImage(img, {
                    x: rect.left + r.left * scale, y: rect.top + r.top * scale,
                    width: r.width * scale, height: r.height * scale,
                })
                return
            }
        }

        const x = rect.left + e.clientX * scale
        const side = window.innerWidth * sideZoneFraction
        const zone = x < side ? 'left' : x > window.innerWidth - side ? 'right' : 'centre'
        post('click', { zone })
    })
    // Context menus are WebKit's own (Look Up, Translate, Copy, Share…);
    // Swift adds Platen's items, using the selection reported here.
    let selectionTimer
    doc.addEventListener('selectionchange', () => {
        clearTimeout(selectionTimer)
        selectionTimer = setTimeout(() => reportSelection(doc, index), 120)
    })
}

// Sends a picture's bytes and on-screen position to Swift, which shows it
// full size (with Copy and Save) in a native view. The image's src is a
// blob: URL made by foliate-js, so reading it stays inside the page.
async function zoomImage(img, rect) {
    try {
        const blob = await (await fetch(img.currentSrc || img.src)).blob()
        // Base64, built in chunks (String.fromCharCode has an argument limit).
        const bytes = new Uint8Array(await blob.arrayBuffer())
        let binary = ''
        for (let i = 0; i < bytes.length; i += 0x8000)
            binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
        post('image', { data: btoa(binary), mimeType: blob.type, alt: img.alt ?? '', rect })
    } catch (e) {
        post('log', { level: 'error', message: `image zoom failed: ${e}` })
    }
}

// ---------------------------------------------------------------------------
// Readable colours
//
// The theme sets the page's background and text colour, but a book's own
// styles can still colour particular elements: headings in black, say, which
// vanish on the Dark and Black themes. After each section loads (and when the
// theme changes) every element with text is checked against the background
// it sits on, and any colour with too little contrast is replaced by the
// theme's text colour. Colours that are readable are left alone, so
// publishers' coloured headings survive where they work.

// WCAG relative luminance and contrast ratio.
const parseColour = value => {
    const m = /rgba?\(([^)]+)\)/.exec(value ?? '')
    if (!m) return null
    const [r, g, b, a = 1] = m[1].split(/[ ,/]+/).filter(Boolean).map(Number)
    return { r, g, b, a }
}
const luminance = ({ r, g, b }) => {
    const channel = c => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4 }
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}
const contrast = (x, y) => {
    const [a, b] = [luminance(x), luminance(y)].sort((p, q) => q - p)
    return (a + 0.05) / (b + 0.05)
}
const hexColour = hex => {
    const n = parseInt(hex.replace('#', ''), 16)
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a: 1 }
}

// Below this ratio text is hard to read (WCAG's minimum for large text).
const minContrast = 3

function ensureReadableColours(doc) {
    if (!settings || !doc?.body) return
    const win = doc.defaultView
    const pageBackground = hexColour(settings.theme.background)
    // Undo earlier fixes first: the theme may have changed.
    for (const el of doc.querySelectorAll('[data-platen-colour]')) {
        el.style.removeProperty('color')
        el.removeAttribute('data-platen-colour')
    }
    // The background an element's text is drawn on: its own, or the
    // nearest ancestor's that is not transparent (the page, by default).
    const backgroundOf = el => {
        for (let e = el; e && e !== doc.body && e !== doc.documentElement; e = e.parentElement) {
            const bg = parseColour(win.getComputedStyle(e).backgroundColor)
            if (bg && bg.a > 0.5) return bg
        }
        return pageBackground
    }
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, {
        acceptNode: n => n.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
    })
    const seen = new Set()
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const el = node.parentElement
        if (!el || seen.has(el)) continue
        seen.add(el)
        const colour = parseColour(win.getComputedStyle(el).color)
        if (!colour) continue
        const background = backgroundOf(el)
        if (background !== pageBackground) continue // a box of the publisher's own: leave it
        if (contrast(colour, pageBackground) < minContrast) {
            el.style.setProperty('color', settings.theme.foreground, 'important')
            el.setAttribute('data-platen-colour', '')
        }
    }
}

// ---------------------------------------------------------------------------
// Publisher font sizes
//
// The text size setting works by setting the font size of the book's root
// element; everything sized in em, rem or % follows it. Some books size their
// text in px or pt, or with keywords such as "small", which ignore the root
// size, so the setting appears to do nothing. Those values are rewritten to
// rem here (16 px = 1 rem, the size the publisher had in mind), so they keep
// their proportions but follow the setting. px line heights are rewritten
// too, or lines would overlap at larger sizes.

const keywordSizes = {
    'xx-small': 0.5625, 'x-small': 0.625, 'small': 0.8125, 'medium': 1,
    'large': 1.125, 'x-large': 1.5, 'xx-large': 2, 'xxx-large': 3,
}

const toRem = value => {
    const v = value.trim().toLowerCase()
    const m = /^(-?\d*\.?\d+)(px|pt)$/.exec(v)
    if (m) {
        const px = parseFloat(m[1]) * (m[2] === 'pt' ? 4 / 3 : 1)
        return `${+(px / 16).toFixed(4)}rem`
    }
    return keywordSizes[v] ? `${keywordSizes[v]}rem` : null
}

const rescaleStyle = style => {
    for (const prop of ['font-size', 'line-height']) {
        const value = style.getPropertyValue(prop)
        if (!value || (prop === 'line-height' && !/px|pt$/i.test(value.trim()))) continue
        const rem = toRem(value)
        if (rem) style.setProperty(prop, rem, style.getPropertyPriority(prop))
    }
}

const rescaleRules = rules => {
    for (const rule of rules) {
        if (rule.style) rescaleStyle(rule.style)
        if (rule.cssRules) rescaleRules(rule.cssRules) // @media, @supports…
    }
}

function rescalePublisherFontSizes(doc) {
    for (const sheet of doc.styleSheets) {
        if (sheet.ownerNode?.textContent?.includes('platen-styles')) continue
        try { rescaleRules(sheet.cssRules) } catch { /* unreadable sheet */ }
    }
    for (const el of doc.querySelectorAll('[style]')) rescaleStyle(el.style)
    // Old-style <font size="1-7"> (common in converted MOBI files).
    const fontSizes = [0, 0.625, 0.8125, 1, 1.125, 1.5, 2, 3]
    for (const el of doc.querySelectorAll('font[size]')) {
        const n = parseInt(el.getAttribute('size'), 10)
        if (n >= 1 && n <= 7) el.style.fontSize = `${fontSizes[n]}rem`
    }
}

// Tells Swift what is selected, with the chapter and printed page it is on,
// for Copy with Citation and "Search Book for …".
const reportSelection = (doc, index) => {
    const selection = doc.getSelection()
    const text = selection?.toString().trim() ?? ''
    if (!text || !selection.rangeCount) return post('selection', { text: '' })
    const range = selection.getRangeAt(0)
    const { tocItem, pageItem } = view.getProgressOf(index, range) ?? {}
    post('selection', {
        text,
        chapter: tocItem?.label?.trim() ?? '',
        page: pageItem?.label ?? null,
    })
}

// Tables wider than a page would spill into the next column, over its text.
// WebKit ignores max-width on tables, so once laid out, any table wider than
// the page is set to the page's width. (foliate-js notices the change in size
// and re-paginates.)
function fitWideTables(doc) {
    // foliate-js lays pages out as CSS columns on the root element.
    const pageWidth = parseFloat(getComputedStyle(doc.documentElement).columnWidth)
        || doc.body?.getBoundingClientRect().width
    if (!pageWidth) return
    for (const table of doc.querySelectorAll('table'))
        if (table.getBoundingClientRect().width > pageWidth + 1)
            table.style.setProperty('width', '100%', 'important')
}

// ---------------------------------------------------------------------------
// Trackpad swipes (paginated mode)
//
// Swift reads the trackpad gesture natively, where it can tell when the
// fingers touch and lift and can ignore momentum, and sends it here: the
// page follows the fingers, then settles on the next page or springs back.
// One gesture never moves more than one page. Vertical scrolling and mouse
// wheels are turned into single page turns in Swift.

const swipe = {
    move(dx) {
        if (!view || isFixedLayout) return
        ribbons.hidden = true // they would not move with the page
        view.renderer.scrollBy?.(dx, 0)
    },
    // direction: 1 or -1 for a flick, which turns the page however short
    // it was; 0 to settle on whichever page is mostly in view.
    end(direction) {
        if (!view || isFixedLayout) return
        // A swipe always settles with a slide, whatever the page-turn
        // setting (unless Reduce Motion is on).
        const r = view.renderer
        const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches
        const animated = r.hasAttribute('animated')
        if (!reduceMotion) r.setAttribute('animated', '')
        r.snap?.(direction, 0)
        if (!animated) setTimeout(() => {
            if (!(settings?.animated)) r.removeAttribute('animated')
        }, 400)
        ribbons.hidden = false
    },
}

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
let lastReason = null
const onRelocate = ({ detail }) => {
    const { cfi, fraction, tocItem, pageItem, location, section } = detail
    const r = view.renderer
    const pagesLeft = !isFixedLayout && settings?.flow !== 'scrolled' && r.pages > 0
        ? Math.max(0, r.pages - 2 - r.page) : null
    // foliate reports *why* the view moved on the renderer's event, which
    // fires after this one; read it once the current dispatch has finished.
    queueMicrotask(() => {
        noteMovement(lastReason)
        scheduleRibbons()
        updatePageNumbers(detail)
        // Page width changes with the layout; re-check tables each time.
        if (!isFixedLayout && settings?.flow !== 'scrolled')
            for (const { doc } of view.renderer.getContents?.() ?? []) if (doc) fitWideTables(doc)
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
// Page numbers
//
// A number is centred below each page, as in a printed book: one for a single
// page, one under each page of a two-page spread. foliate-js gives each page
// (column) a footer element in the bottom margin.
//
// The numbers are screen pages, so they run in order under every page:
// exact within a chapter, and estimated for where each chapter starts, from
// the size of the text before it. (Printed page numbers, where a book has
// them, span several screen pages; they are used for citations, bookmarks
// and "Back to p. 87" instead.) The estimate is
// calibrated once per layout (text size, window size…), so numbers do not
// shift as the reader moves between chapters.

let pagesPerBook = null    // estimated screen pages in the whole book
let calibratedFor = ''     // the layout the estimate was made for

// The numbers are drawn in a strip of our own rather than in foliate's
// footers, which stay put while the text moves. The strip holds numbers for
// the spread on screen and the spreads either side, and slides with the text
// during a swipe, so each number stays under its page.
// The strip sits in a window the width of the page area, so the numbers of
// the neighbouring pages (ready to slide in) are hidden in the margins.
const numberWindow = document.createElement('div')
numberWindow.id = 'page-numbers'
numberWindow.setAttribute('aria-hidden', 'true') // the overlay says where you are
const numberStrip = document.createElement('div')
numberWindow.append(numberStrip)
document.body.append(numberWindow)
let stripStart = 0 // the scroll position the strip was laid out for

function updatePageNumbers(detail) {
    const r = view?.renderer
    const feet = r?.feet
    numberStrip.replaceChildren()
    numberStrip.style.transform = ''
    // The page area is centred in the window and one "page" (spread) wide.
    if (r?.size) {
        const left = Math.max(0, (innerWidth - r.size) / 2)
        numberWindow.style.left = `${left}px`
        numberWindow.style.width = `${r.size}px`
        numberStrip.style.left = `${-left}px`
    }
    if (!feet?.length || isFixedLayout || settings?.flow === 'scrolled') return
    const columns = feet.length
    const index = detail.section?.current ?? r.getContents?.()[0]?.index
    const fractions = view.getSectionFractions?.() ?? []
    // foliate's paginator adds a blank page before and after each section.
    const textPages = r.pages - 2
    const columnsInSection = textPages * columns
    const firstColumn = (r.page - 1) * columns

    // label(column in section) → the number under that page.
    const layout = [settings.fontSize, settings.lineHeight, settings.lineWidth, settings.fontFamily,
                    columns, innerWidth, innerHeight].join('|')
    const share = (fractions[index + 1] ?? 1) - (fractions[index] ?? 0)
    if (calibratedFor !== layout && share > 0 && columnsInSection >= 4) {
        pagesPerBook = columnsInSection / share
        calibratedFor = layout
    }
    if (!pagesPerBook) return
    const sectionStart = Math.round((fractions[index] ?? 0) * pagesPerBook)
    const label = column => column >= 0 && column < columnsInSection ? String(sectionStart + column + 1) : ''

    // Where each page's number goes: the centre of foliate's (empty) footer
    // cell for that column. Spreads either side are a page-width away.
    const rtl = view.book?.dir === 'rtl'
    const cells = feet.map(el => el.parentElement.getBoundingClientRect())
    for (const spread of [-1, 0, 1]) {
        cells.forEach((cell, i) => {
            const text = label(firstColumn + spread * columns + i)
            if (!text) return
            const el = document.createElement('span')
            el.textContent = text
            el.style.left = `${cell.left + cell.width / 2 + spread * r.size * (rtl ? -1 : 1)}px`
            el.style.top = `${cell.top}px`
            el.style.height = el.style.lineHeight = `${cell.height}px`
            numberStrip.append(el)
        })
    }
    stripStart = r.start
}

// Keep the strip under the text while it moves (swipes, snapping back).
function followScroll() {
    const r = view?.renderer
    if (!r || !numberStrip.childElementCount) return
    const delta = r.start - stripStart
    const rtl = view.book?.dir === 'rtl'
    numberStrip.style.transform = `translateX(${rtl ? delta : -delta}px)`
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
            view.addEventListener('load', ({ detail: { doc, index } }) => {
                if (!isFixedLayout) {
                    rescalePublisherFontSizes(doc)
                    ensureReadableColours(doc)
                }
                attachPointerHandlers(doc, index)
            })
            view.renderer.addEventListener('relocate', e => { lastReason = e.detail.reason })
            view.renderer.addEventListener('scroll', followScroll)
            view.addEventListener('external-link', e => {
                // Never navigate the reader; let Swift open it in the browser.
                e.preventDefault()
                post('externalLink', { href: e.detail.a.href })
            })
            // Following a link is a jump: offer a way back.
            view.addEventListener('link', () => rememberJumpOrigin())
            applyLayout()

            // Restore the saved position, or start where the main text begins.
            await view.init({ lastLocation: options.lastCFI ?? null, showTextStart: true })

            post('opened', {
                title: metadataString(book.metadata?.title),
                author: metadataString(book.metadata?.author),
                language: metadataString(book.metadata?.language),
                dir: book.dir ?? 'ltr',
                fixedLayout: isFixedLayout,
                hasPageList: !!book.pageList?.length,
                sectionFractions: view.getSectionFractions(),
            })
            // Contents and chapter labels are worked out after the first page
            // is on screen, so they never delay opening.
            setTimeout(() => sendContents(book), 0)
        } catch (e) {
            post('error', { message: String(e?.message ?? e), stack: String(e?.stack ?? '') })
        }
    },
    setSettings(s) {
        const themeChanged = s.theme?.background !== settings?.theme?.background
        settings = s
        applyLayout()
        if (themeChanged && !isFixedLayout)
            for (const { doc } of view?.renderer?.getContents?.() ?? []) ensureReadableColours(doc)
    },
    goLeft: () => view?.goLeft(),
    goRight: () => view?.goRight(),
    next: () => view?.next(),
    prev: () => view?.prev(),
    // Scroll mode: arrow keys move by a fraction of a screen.
    scrollLines: lines => lines > 0 ? view?.next(lines * 40) : view?.prev(-lines * 40),
    nextSection: () => view?.renderer.nextSection?.(),
    prevSection: () => view?.renderer.prevSection?.(),
    // Jumps (contents, bookmarks, search results, slider) remember where
    // the reader came from, for the Back button.
    // `keepOrigin`: stepping through search results keeps "Back" pointing
    // at where the reader was before the first result.
    jumpTo: (target, keepOrigin) => jump(() => view.goTo(target), keepOrigin),
    jumpToFraction: f => jump(() => view.goToFraction(f)),
    goBack,
    setBookmarks(list) {
        bookmarks = list ?? []
        scheduleRibbons()
    },
    toggleBookmark,
    search,
    // For the page-turn animation (drawn natively from snapshots): turn
    // with no slide, and resolve once the new page has been painted. Says
    // whether the page changed and how many pages are side by side.
    async turnInstantly(direction) {
        if (!view) return { moved: false, columns: 1 }
        const r = view.renderer
        const before = view.lastLocation?.cfi
        const animated = r.hasAttribute('animated')
        r.removeAttribute('animated')
        const relocated = new Promise(resolve => {
            const timer = setTimeout(resolve, 400) // at the start or end of the book
            view.addEventListener('relocate', () => { clearTimeout(timer); resolve() }, { once: true })
        })
        ;({ left: () => view.goLeft(), right: () => view.goRight(),
            next: () => view.next(), prev: () => view.prev() })[direction]?.()
        await relocated
        if (animated) r.setAttribute('animated', '')
        // Two frames: the first lays out, the second is on screen.
        await new Promise(requestAnimationFrame)
        await new Promise(requestAnimationFrame)
        const columns = isFixedLayout ? Math.max(1, pagesOnScreen().length) : (r.feet?.length ?? 1)
        return { moved: view.lastLocation?.cfi !== before, columns }
    },
    swipeMove: dx => swipe.move(dx),
    swipeEnd: direction => swipe.end(direction),
    // For debugging and automated checks (scripts/run-debug.sh steps).
    get view() { return view },
    clearSearch() {
        searchToken++
        view?.clearSearch()
    },
}


// ---------------------------------------------------------------------------
// Jumps and the Back button
//
// After a jump (contents, link, bookmark, search, slider), the overlay offers
// "Back to p. 87" or "Back to Chapter 3". It stays until the reader moves on
// from the destination by turning a page.

let back = null          // { cfi, label }
let jumpStartedAt = 0

const describeLocation = () => {
    const l = view?.lastLocation
    if (!l?.cfi) return null
    const page = l.pageItem?.label
    const chapter = l.tocItem?.label?.trim()
    const label = page ? `p. ${page}` : chapter || `${Math.round((l.fraction ?? 0) * 100)}%`
    return { cfi: l.cfi, label }
}

const rememberJumpOrigin = keepOrigin => {
    const origin = describeLocation()
    jumpStartedAt = performance.now()
    if (keepOrigin && back) return
    if (!origin) return
    back = origin
    post('back', { label: back.label })
}

async function jump(go, keepOrigin = false) {
    rememberJumpOrigin(keepOrigin)
    await go()
}

function goBack() {
    if (!back) return
    const target = back.cfi
    back = null
    post('back', { label: null })
    jumpStartedAt = performance.now()
    return view.goTo(target)
}

// Called for every relocation with foliate's reason. Re-layouts ("anchor")
// and the jump's own arrival do not count as moving on.
function noteMovement(reason) {
    if (!back || reason === 'anchor') return
    if (performance.now() - jumpStartedAt < 700) return
    back = null
    post('back', { label: null })
}

// ---------------------------------------------------------------------------
// Bookmarks
//
// A bookmark is anchored to the CFI of the first word on a page. In a
// two-page spread each page has its own top-right corner and bookmark. The
// ribbons are drawn in the shell, above the book, so they never touch the
// book's own document.

let bookmarks = []   // [{ cfi }], from Swift

const ribbons = document.createElement('div')
ribbons.id = 'ribbons'
document.body.append(ribbons)

const ribbonSVG = `<svg viewBox="0 0 14 24" width="14" height="24" aria-hidden="true">
    <path d="M1 0h12v23l-6-5-6 5z"/></svg>`

// The pages on screen, each with its bounds (window coordinates), the CFI
// and text of its first word, and its chapter and printed page.
function pagesOnScreen() {
    if (!view) return []
    const contents = view.renderer.getContents?.() ?? []
    if (isFixedLayout) {
        // Fixed layout: the bookmark is simply the page (section) itself.
        return contents.filter(c => c.doc && c.index >= 0
                                     && c.doc.defaultView.frameElement.getBoundingClientRect().width > 0)
            .map(({ doc, index }) => {
            const r = doc.defaultView.frameElement.getBoundingClientRect()
            return { left: r.left, right: r.right, top: r.top, index,
                     cfi: view.getCFI(index), snippet: doc.body?.innerText?.trim().slice(0, 100) ?? '',
                     ...labelsFor(index) }
        }).filter(p => p.right > 0 && p.left < innerWidth)
    }
    const location = view.lastLocation
    const { doc, index } = contents[0] ?? {}
    if (!doc || !location?.range) return []
    const frame = doc.defaultView.frameElement
    const fr = frame.getBoundingClientRect()
    const scale = frame.offsetWidth ? fr.width / frame.offsetWidth : 1
    const toWindow = r => ({ left: fr.left + r.left * scale, right: fr.left + r.right * scale,
                             top: fr.top + r.top * scale, bottom: fr.top + r.bottom * scale })

    // Every line box of the visible text, grouped into columns (pages) by
    // horizontal position.
    const boxes = Array.from(location.range.getClientRects())
        .filter(r => r.width > 0 && r.height > 0)
        .map(r => ({ r, w: toWindow(r) }))
        .filter(({ w }) => w.right > 0 && w.left < innerWidth && w.bottom > 0 && w.top < innerHeight)
        .sort((a, b) => a.w.left - b.w.left)
    const columns = []
    for (const box of boxes) {
        const column = columns.at(-1)
        if (column && box.w.left < column.right + 8) {
            column.boxes.push(box)
            column.right = Math.max(column.right, box.w.right)
        } else columns.push({ left: box.w.left, right: box.w.right, boxes: [box] })
    }
    return columns.map(column => {
        const first = column.boxes.reduce((a, b) =>
            b.w.top < a.w.top - 1 || (Math.abs(b.w.top - a.w.top) <= 1 && b.w.left < a.w.left) ? b : a)
        const caret = doc.caretRangeFromPoint(first.r.left + 1, first.r.top + first.r.height / 2)
        if (!caret) return null
        const rest = doc.createRange()
        rest.setStart(caret.startContainer, caret.startOffset)
        rest.setEnd(location.range.endContainer, location.range.endOffset)
        const snippet = rest.toString().replace(/\s+/g, ' ').trim().slice(0, 100)
        const { tocItem, pageItem } = view.getProgressOf(index, caret) ?? {}
        return { left: column.left, right: column.right, top: first.w.top, index,
                 cfi: view.getCFI(index, caret), snippet,
                 chapter: tocItem?.label?.trim() ?? '', page: pageItem?.label ?? null,
                 contains: w => w.left >= column.left - 4 && w.left <= column.right + 4
                     && w.bottom > 0 && w.top < innerHeight }
    }).filter(Boolean)
}

function labelsFor(index) {
    const { tocItem, pageItem } = view.getProgressOf(index) ?? {}
    return { chapter: tocItem?.label?.trim() ?? '', page: pageItem?.label ?? null }
}

// Window rect of a bookmark's anchor, if it is in the current section.
function bookmarkRect(cfi, index, doc) {
    try {
        const resolved = view.resolveNavigation(cfi)
        if (resolved?.index !== index) return null
        if (isFixedLayout) return { section: true }
        const anchor = resolved.anchor(doc)
        const range = anchor instanceof Range ? anchor.cloneRange()
            : (() => { const r = doc.createRange(); r.selectNode(anchor); return r })()
        // A collapsed range (a bookmark is a point) has no boxes in WebKit;
        // widen it to the character that follows so it can be located.
        if (range.collapsed && range.startContainer.nodeType === Node.TEXT_NODE
            && range.startOffset < range.startContainer.length) range.setEnd(range.startContainer, range.startOffset + 1)
        const r = Array.from(range.getClientRects()).find(x => x.width || x.height) ?? range.getBoundingClientRect()
        if (!r.width && !r.height) return null
        const frame = doc.defaultView.frameElement
        const fr = frame.getBoundingClientRect()
        const scale = frame.offsetWidth ? fr.width / frame.offsetWidth : 1
        return { left: fr.left + r.left * scale, top: fr.top + r.top * scale,
                 bottom: fr.top + r.bottom * scale }
    } catch { return null }
}

let pagesCache = []
let ribbonFrame = 0
let lastBookmarkedState = null

// foliate can report several relocations for one page turn (layout, fonts
// loading…). Redraw the ribbons once per frame at most.
function scheduleRibbons() {
    cancelAnimationFrame(ribbonFrame)
    ribbonFrame = requestAnimationFrame(refreshRibbons)
}

function refreshRibbons() {
    ribbons.replaceChildren()
    if (!view) return
    const pages = pagesCache = pagesOnScreen()
    const contents = view.renderer.getContents?.() ?? []
    const scrolled = settings?.flow === 'scrolled' && !isFixedLayout
    let anyMarked = false

    for (const page of pages) {
        const doc = contents.find(c => c.index === page.index)?.doc
        // Which saved bookmarks fall on this page?
        const marks = bookmarks.map(b => ({ b, rect: doc && bookmarkRect(b.cfi, page.index, doc) }))
            .filter(({ b, rect }) => b.cfi === page.cfi || (rect && !rect.section && page.contains?.(rect)))
            .map(({ b, rect }) => ({ b, rect: rect ?? { top: page.top } }))
        if (isFixedLayout) marks.splice(0, marks.length, ...bookmarks
            .filter(b => b.cfi === page.cfi).map(b => ({ b, rect: { section: true } })))

        // Paginated: one corner per page, at its top right. Scroll mode: the
        // corner for adding sits at the top; existing ribbons sit level with
        // their line.
        const corner = (marked, top, cfi) => {
            const el = document.createElement('button')
            el.className = 'corner' + (marked ? ' marked' : '')
            el.style.left = `${Math.round(page.right - 30)}px`
            el.style.top = `${Math.round(top)}px`
            el.innerHTML = ribbonSVG
            el.setAttribute('aria-label', marked ? 'Remove Bookmark' : 'Bookmark This Page')
            el.tabIndex = -1 // reachable via ⌘D and the menu instead
            el.addEventListener('click', e => {
                e.stopPropagation()
                if (marked) post('removeBookmark', { cfi })
                else post('addBookmark', bookmarkPayload(page))
            })
            ribbons.append(el)
        }
        const topEdge = 28 // just below the title bar
        if (marks.length) {
            anyMarked ||= page === leadingPage(pages)
            for (const { b, rect } of marks)
                corner(true, scrolled && !rect.section ? Math.max(topEdge, rect.top - 4) : topEdge, b.cfi)
        }
        if (!marks.length || scrolled) {
            if (!(scrolled && marks.some(({ rect }) => Math.abs(Math.max(topEdge, rect.top - 4) - topEdge) < 30)))
                corner(false, topEdge, null)
        }
    }
    if (anyMarked !== lastBookmarkedState) {
        lastBookmarkedState = anyMarked
        post('pageBookmarked', { bookmarked: anyMarked })
    }
}

const bookmarkPayload = page => ({
    cfi: page.cfi, snippet: page.snippet, chapter: page.chapter, page: page.page,
    fraction: view?.lastLocation?.fraction ?? null,
})

// The page a keyboard command applies to: the first page in reading order.
const leadingPage = pages => (view?.book?.dir === 'rtl' ? pages.at(-1) : pages[0])

// ⌘D: bookmark the leading page, or remove its bookmark.
function toggleBookmark() {
    const page = leadingPage(pagesCache.length ? pagesCache : pagesOnScreen())
    if (!page) return
    const doc = (view.renderer.getContents?.() ?? []).find(c => c.index === page.index)?.doc
    const existing = bookmarks.find(b => isFixedLayout ? b.cfi === page.cfi
        : b.cfi === page.cfi || (() => { const r = doc && bookmarkRect(b.cfi, page.index, doc); return r && page.contains(r) })())
    if (existing) post('removeBookmark', { cfi: existing.cfi })
    else post('addBookmark', bookmarkPayload(page))
}

// ---------------------------------------------------------------------------
// Find in book

let searchToken = 0

async function search(query) {
    const token = ++searchToken
    view?.clearSearch()
    if (!view || !query) return post('searchDone', { query, count: 0 })
    let count = 0
    try {
        for await (const result of view.search({
            query,
            draw: Overlayer.highlight,
            drawOptions: { color: '#ffcc00' },
        })) {
            if (token !== searchToken) return // superseded by a newer search
            if (result === 'done') break
            if (result.subitems) {
                count += result.subitems.length
                post('searchResults', {
                    query,
                    label: result.label?.trim() ?? '',
                    items: result.subitems.map(({ cfi, excerpt }) => ({
                        cfi, pre: excerpt?.pre ?? '', match: excerpt?.match ?? '', post: excerpt?.post ?? '',
                    })),
                })
            } else if (typeof result.progress === 'number') {
                post('searchProgress', { query, progress: result.progress })
            }
        }
    } catch (e) {
        post('log', { level: 'error', message: `search failed: ${e}` })
    }
    if (token === searchToken) post('searchDone', { query, count })
}

// ---------------------------------------------------------------------------
// Contents
//
// Books without a table of contents get one built from their sections'
// first headings. Each section also gets a chapter label, used by the
// slider while dragging and for books without a contents list.

async function synthesiseContents(book) {
    const items = []
    for (const section of book.sections) {
        if (section.linear === 'no' || !section.createDocument) continue
        try {
            const doc = await section.createDocument()
            const heading = doc.querySelector('h1, h2, h3, h4, h5, h6')
            const text = (heading?.textContent || doc.title || '').replace(/\s+/g, ' ').trim()
            items.push({ label: text || `Section ${items.length + 1}`, href: section.id, depth: 0 })
        } catch { /* unreadable section: leave it out */ }
    }
    return items
}

async function sendContents(book) {
    let toc = flattenTOC(book.toc)
    const synthesised = !toc.length
    if (synthesised) toc = await synthesiseContents(book)
    const byHref = new Map(toc.map(t => [t.href, t.label]))
    let last = ''
    const sectionLabels = book.sections.map((section, i) => {
        const label = synthesised ? byHref.get(section.id) : view.getProgressOf(i)?.tocItem?.label?.trim()
        if (label) last = label
        return last
    })
    post('contents', { toc, sectionLabels, synthesised })
}

post('ready')
