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

// The saved bookmarks, from Swift.
function setBookmarkList(list) {
    bookmarks = list ?? []
    scheduleRibbons()
}

const ribbons = document.createElement('div')
ribbons.id = 'ribbons'
document.body.append(ribbons)

const ribbonSVG = `<svg viewBox="0 0 14 24" width="14" height="24" aria-hidden="true">
    <path d="M1 0h12v23l-6-5-6 5z"/></svg>`

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

export { pagesOnScreen, ribbons, scheduleRibbons, setBookmarkList, toggleBookmark }
