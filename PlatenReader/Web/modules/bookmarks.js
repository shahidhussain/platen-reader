// Platen Reader: Bookmarks: the ribbons in each page corner, adding and removing.

import { reader } from './state.js'
import { post } from './bridge.js'

// ---------------------------------------------------------------------------
// Bookmarks
//
// A bookmark is anchored to the CFI of the first word on a page. In a
// two-page spread each page has its own top-right corner and bookmark. The
// ribbons are drawn in the shell, above the book, so they never touch the
// book's own document.

let bookmarks = []   // [{ cfi }], from Swift

// The saved bookmarks, from Swift. A bookmark that has just been added is
// laid onto its page, and one just removed lifts off it (see `ribbonMotion`);
// turning onto a bookmarked page shows its ribbon simply there.
function setBookmarkList(list) {
    const before = new Set(bookmarks.map(b => b.cfi))
    bookmarks = list ?? []
    const after = new Set(bookmarks.map(b => b.cfi))
    for (const cfi of after) if (!before.has(cfi)) arriving.add(cfi)
    for (const cfi of before) if (!after.has(cfi)) liftOff(cfi)
    scheduleRibbons()
}

const ribbons = document.createElement('div')
ribbons.id = 'ribbons'
document.body.append(ribbons)
// Ribbons lifting off: kept apart, so a redraw of the others leaves them be.
const leaving = document.createElement('div')
leaving.id = 'ribbons-leaving'
document.body.append(leaving)

// The ribbon is a drawn picture of orange grosgrain with stitched edges and
// a swallowtail notch (design/ribbon/make-ribbon.swift), in light and dark.
// Unmarked corners show only the faint outline of its shape (on hover, on
// the Mac), which makes the feature discoverable.
const ribbonOutline = `<svg viewBox="0 0 20 30" aria-hidden="true" preserveAspectRatio="none">
    <path d="M.5 0v29.5l9.5-6.4 9.5 6.4V0"/></svg>`
const ribbonPicture = dark => {
    // A strip of cloth that repeats down the ribbon's length, whatever it
    // is, and the notched end below it.
    const name = dark ? 'dark' : 'light'
    const strip = `-webkit-image-set(url(ribbon/ribbon-strip-${name}@2x.png) 2x, url(ribbon/ribbon-strip-${name}@3x.png) 3x)`
    return `<span class="strip" style="background-image: ${strip}"></span><img class="end" alt="" draggable="false"
        src="ribbon/ribbon-end-${name}@2x.png" srcset="ribbon/ribbon-end-${name}@2x.png 2x, ribbon/ribbon-end-${name}@3x.png 3x">`
}

// The ribbon's motions, in seconds and degrees: Swift sends them from
// PlatenMotion.Ribbon (PlatenPress.swift), where all the decorative motion's
// numbers are kept. These are the same values, until it does.
let ribbonMotion = { layDuration: .2, layStartFold: 80, layStartSwing: 15, settleSwing: 1.5,
                     settleDuration: .15, liftDuration: .15, reducedDuration: .15 }
function setRibbonMotion(motion) { ribbonMotion = { ...ribbonMotion, ...motion } }

// Bookmarks just added, whose ribbons are still to be laid down.
const arriving = new Set()
const reduceMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches

// The ribbon's pose part-way through laying it down or lifting it off:
// folded `fold` degrees about the page's top edge towards the reader, and
// turned `turn` degrees off vertical. The perspective is weak, and set from
// the ribbon's length (ten times it, or more): with a strong one, the end
// tipped towards the reader looked longer than the whole ribbon part-way
// down, and flicked past where it lands (device testing, 26 Nov 2026).
const ribbonPose = (el, fold, turn) => {
    const distance = Math.max(600, (el.getBoundingClientRect().height || 45) * 10)
    return `perspective(${Math.round(distance)}px) rotateX(${fold}deg) rotate(${turn}deg)`
}

// Laying a ribbon onto its page: hinged at the page's top edge, it folds
// down from nearly end-on (held up towards the reader) to lie flat, coming
// in from the page's outer side, angled off vertical, and straightening as
// it lands. It slows to a stop as it meets the page (cloth does not
// stretch: no overshoot, no bounce), then swings a degree or two from the
// top edge, dying away. With Reduce Motion, a fade.
function layDown(el, outerIsLeft) {
    const m = ribbonMotion
    if (reduceMotion()) {
        el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: m.reducedDuration * 1000, easing: 'linear' })
        return
    }
    const swing = outerIsLeft ? 1 : -1 // the bottom swings in from the outer side
    const total = m.layDuration + m.settleDuration
    const landed = m.layDuration / total
    const pose = (fold, turn) => ribbonPose(el, fold, turn)
    el.animate([
        { offset: 0, transform: pose(m.layStartFold, swing * m.layStartSwing), easing: 'cubic-bezier(.15,.6,.3,1)' },
        { offset: landed, transform: pose(0, 0), easing: 'ease-out' },
        { offset: landed + (1 - landed) * .35, transform: pose(0, -swing * m.settleSwing), easing: 'ease-in-out' },
        { offset: landed + (1 - landed) * .7, transform: pose(0, swing * m.settleSwing * .35), easing: 'ease-in-out' },
        { offset: 1, transform: pose(0, 0) },
    ], { duration: total * 1000 })
}

// Taking a ribbon off: laying it down played backwards. It lifts off the
// page towards the reader, folding up about the top edge to nearly end-on,
// and swings back out to the side it came in from, gathering speed as it
// goes (no settling swing). It fades only at the very end, when it is all
// but edge-on, so it reads as lifted away rather than faded out (the
// reader's request, 26 Nov 2026). With Reduce Motion, a fade.
function liftOff(cfi) {
    const el = ribbons.querySelector(`.corner.marked[data-cfi="${CSS.escape(cfi)}"]`)
    if (!el) return
    const ghost = el.cloneNode(true)
    ghost.style.pointerEvents = 'none'
    leaving.append(ghost)
    const m = ribbonMotion
    const ribbon = ghost.querySelector('.ribbon')
    const swing = ghost.dataset.outerLeft === 'true' ? 1 : -1
    const frames = reduceMotion()
        ? [{ opacity: 1 }, { opacity: 0 }]
        : [{ offset: 0, transform: ribbonPose(ribbon, 0, 0), opacity: 1 },
           { offset: .8, transform: ribbonPose(ribbon, m.layStartFold * .8, swing * m.layStartSwing * .8), opacity: 1 },
           { offset: 1, transform: ribbonPose(ribbon, m.layStartFold, swing * m.layStartSwing), opacity: 0 }]
    const lift = ribbon.animate(frames, {
        duration: (reduceMotion() ? m.reducedDuration : m.liftDuration) * 1000,
        easing: 'cubic-bezier(.7,0,.85,.4)', fill: 'forwards' })
    lift.onfinish = lift.oncancel = () => ghost.remove()
}

// iOS: whether the controls are up, and where their top bar ends (points).
let headerBottom = 0
function setControlsVisible(on, bottom) {
    if (bottom && Math.abs(bottom - headerBottom) > .5) {
        headerBottom = bottom
        scheduleRibbons()
    }
    ribbons.classList.toggle('with-controls', !!on)
}

// Any input during a ribbon's motion ends it at once, where it would end.
function finishRibbonMotion() {
    for (const el of [...ribbons.querySelectorAll('.ribbon'), ...leaving.querySelectorAll('.ribbon')])
        for (const animation of el.getAnimations()) animation.finish()
}
for (const type of ['pointerdown', 'keydown', 'wheel'])
    addEventListener(type, finishRibbonMotion, { capture: true, passive: true })

// The pages on screen, each with its bounds (window coordinates), the CFI
// and text of its first word, and its chapter and printed page.
function pagesOnScreen() {
    if (!reader.view) return []
    const contents = reader.view.renderer.getContents?.() ?? []
    if (reader.isFixedLayout) {
        // Fixed layout: the bookmark is simply the page (section) itself.
        return contents.filter(c => c.doc && c.index >= 0
                                     && c.doc.defaultView.frameElement.getBoundingClientRect().width > 0)
            .map(({ doc, index }) => {
            const r = doc.defaultView.frameElement.getBoundingClientRect()
            return { left: r.left, right: r.right, top: r.top, index,
                     cfi: reader.view.getCFI(index), snippet: doc.body?.innerText?.trim().slice(0, 100) ?? '',
                     ...labelsFor(index) }
        }).filter(p => p.right > 0 && p.left < innerWidth)
    }
    const location = reader.view.lastLocation
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
        const { tocItem, pageItem } = reader.view.getProgressOf(index, caret) ?? {}
        return { left: column.left, right: column.right, top: first.w.top, index,
                 cfi: reader.view.getCFI(index, caret), snippet,
                 chapter: tocItem?.label?.trim() ?? '', page: pageItem?.label ?? null,
                 contains: w => w.left >= column.left - 4 && w.left <= column.right + 4
                     && w.bottom > 0 && w.top < innerHeight }
    }).filter(Boolean)
}

function labelsFor(index) {
    const { tocItem, pageItem } = reader.view.getProgressOf(index) ?? {}
    return { chapter: tocItem?.label?.trim() ?? '', page: pageItem?.label ?? null }
}

// Window rect of a bookmark's anchor, if it is in the current section.
function bookmarkRect(cfi, index, doc) {
    try {
        const resolved = reader.view.resolveNavigation(cfi)
        if (resolved?.index !== index) return null
        if (reader.isFixedLayout) return { section: true }
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
let ribbonTimer = 0
function scheduleRibbons() {
    cancelAnimationFrame(ribbonFrame)
    clearTimeout(ribbonTimer)
    const refresh = () => {
        cancelAnimationFrame(ribbonFrame)
        clearTimeout(ribbonTimer)
        refreshRibbons()
    }
    ribbonFrame = requestAnimationFrame(refresh)
    // WebKit pauses animation frames while the window is hidden (behind
    // other windows); the ribbons must still be right when it comes back.
    ribbonTimer = setTimeout(refresh, 100)
}

function refreshRibbons() {
    ribbons.replaceChildren()
    if (!reader.view) return
    const pages = pagesCache = pagesOnScreen()
    const contents = reader.view.renderer.getContents?.() ?? []
    const scrolled = reader.settings?.flow === 'scrolled' && !reader.isFixedLayout
    let anyMarked = false

    for (const page of pages) {
        const doc = contents.find(c => c.index === page.index)?.doc
        // Which saved bookmarks fall on this page?
        const marks = bookmarks.map(b => ({ b, rect: doc && bookmarkRect(b.cfi, page.index, doc) }))
            .filter(({ b, rect }) => b.cfi === page.cfi || (rect && !rect.section && page.contains?.(rect)))
            .map(({ b, rect }) => ({ b, rect: rect ?? { top: page.top } }))
        if (reader.isFixedLayout) marks.splice(0, marks.length, ...bookmarks
            .filter(b => b.cfi === page.cfi).map(b => ({ b, rect: { section: true } })))

        // Paginated: one corner per page, at its top right, hanging from
        // the top within the top margin, never down over the text. Scroll
        // mode: the corner for adding sits at the top; existing ribbons sit
        // level with their line, in the margin beside it when there is room.
        const corner = (marked, top, cfi, beside = false) => {
            const el = document.createElement('button')
            el.className = 'corner' + (marked ? ' marked' : '')
            // Paginated: 16 pixels in from the right-hand edge of the screen,
            // or, in a spread, of the page's own half (the corner's ribbon
            // is 18 pixels in from its left and 20 wide).
            const edge = pages.length > 1 && page.right < innerWidth / 2 ? innerWidth / 2 : innerWidth
            const left = beside ? page.right + 10 : scrolled ? page.right - 16 - ribbonWidth : edge - inset - ribbonWidth - 18
            el.style.left = `${Math.round(left)}px`
            el.style.top = `${Math.round(top)}px`
            el.style.setProperty('--ribbon-height', `${ribbonHeight}px`)
            // iOS, paginated: while the controls are up, the top bar would
            // cover the ribbon, so it is pulled down longer, the same width
            // and from the same place, until its end hangs below the bar
            // (past its band's fade); it shortens again when they go
            // (reader's request, 26 Nov 2026).
            if (marked && touch && !scrolled) {
                el.classList.add('pullable')
                el.style.setProperty('--pulled-height', `${Math.round(Math.max(ribbonHeight, headerBottom + 26 + 34 - top))}px`)
            }
            el.innerHTML = `<span class="ribbon">${marked ? ribbonPicture(reader.settings?.theme?.dark) : ribbonOutline}</span>`
            if (cfi) el.dataset.cfi = cfi
            el.setAttribute('aria-label', marked ? 'Remove Bookmark' : 'Bookmark This Page')
            el.tabIndex = -1 // reachable via ⌘D and the menu instead
            el.addEventListener('click', e => {
                e.stopPropagation()
                if (marked) post('removeBookmark', { cfi })
                else post('addBookmark', bookmarkPayload(page))
            })
            ribbons.append(el)
            // The outer side of the page: the left on the left-hand page of
            // a spread, else the right (it comes in from there, and goes
            // back out that way).
            const outerIsLeft = pages.length > 1 && page.right < innerWidth / 2
            el.dataset.outerLeft = String(outerIsLeft)
            if (marked && arriving.has(cfi)) {
                arriving.delete(cfi)
                layDown(el.querySelector('.ribbon'), outerIsLeft)
            }
        }
        // Paginated, the ribbon hangs from the top of the screen at its
        // right-hand corner (on iOS; it may sit under the status bar's
        // battery when the controls are up), as a PDF's hangs from its
        // page's top edge: a place tied to the page, not to the text
        // (device testing, 25 Nov 2026). On the Mac, just below the title
        // bar, whose strip at the top of the window takes clicks to move
        // the window. In Scroll layout the corner for adding sits just
        // below the title bar or, on iOS, just above the text.
        const touch = !!reader.settings?.touch
        const topEdge = !scrolled ? (touch ? 0 : 28)
            : reader.settings?.verticalMargin ? Math.max(28, reader.settings.verticalMargin - 42) : 28
        // As long as the room above the text allows, up to 30 pixels: 45
        // on iOS (half as big again, to be seen at a glance), hanging far
        // enough in from the edge to clear the screen's rounded corner
        // (`ribbonInset`, from the app).
        const textTop = parseFloat(reader.view.renderer.getAttribute?.('margin')) || 60
        const fullHeight = touch ? 45 : 30
        const ribbonHeight = scrolled ? fullHeight : Math.max(16, Math.min(fullHeight, textTop - topEdge - 8))
        const ribbonWidth = ribbonHeight * 2 / 3
        const inset = reader.settings?.ribbonInset ?? 16
        if (marks.length) {
            anyMarked ||= page === leadingPage(pages)
            const roomBeside = innerWidth - page.right >= 30
            for (const { b, rect } of marks) {
                const level = scrolled && !rect.section
                corner(true, level ? Math.max(topEdge, rect.top - 4) : topEdge, b.cfi, level && roomBeside)
            }
        }
        if (!marks.length || scrolled) {
            if (!(scrolled && marks.some(({ rect }) => Math.abs(Math.max(topEdge, rect.top - 4) - topEdge) < 30)))
                corner(false, topEdge, null)
        }
    }
    // A bookmark added for a page not on screen is not laid down later:
    // turning onto a bookmarked page shows its ribbon simply there.
    arriving.clear()
    if (anyMarked !== lastBookmarkedState) {
        lastBookmarkedState = anyMarked
        post('pageBookmarked', { bookmarked: anyMarked })
    }
}

const bookmarkPayload = page => ({
    cfi: page.cfi, snippet: page.snippet, chapter: page.chapter, page: page.page,
    fraction: reader.view?.lastLocation?.fraction ?? null,
})

// The page a keyboard command applies to: the first page in reading order.
const leadingPage = pages => (reader.view?.book?.dir === 'rtl' ? pages.at(-1) : pages[0])

// ⌘D: bookmark the leading page, or remove its bookmark.
function toggleBookmark() {
    const page = leadingPage(pagesCache.length ? pagesCache : pagesOnScreen())
    if (!page) return
    const doc = (reader.view.renderer.getContents?.() ?? []).find(c => c.index === page.index)?.doc
    const existing = bookmarks.find(b => reader.isFixedLayout ? b.cfi === page.cfi
        : b.cfi === page.cfi || (() => { const r = doc && bookmarkRect(b.cfi, page.index, doc); return r && page.contains(r) })())
    if (existing) post('removeBookmark', { cfi: existing.cfi })
    else post('addBookmark', bookmarkPayload(page))
}

export { pagesOnScreen, ribbons, scheduleRibbons, setBookmarkList, setControlsVisible, setRibbonMotion, toggleBookmark }
