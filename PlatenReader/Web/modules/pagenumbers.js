// Platen Reader: Page numbers under each page.

import { reader } from './state.js'

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
    const r = reader.view?.renderer
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
    if (!feet?.length || reader.isFixedLayout || reader.settings?.flow === 'scrolled') return
    const columns = feet.length
    const index = detail.section?.current ?? r.getContents?.()[0]?.index
    const fractions = reader.view.getSectionFractions?.() ?? []
    // foliate's paginator adds a blank page before and after each section.
    const textPages = r.pages - 2
    const columnsInSection = textPages * columns
    const firstColumn = (r.page - 1) * columns

    // label(column in section) → the number under that page.
    const layout = [reader.settings.fontSize, reader.settings.lineHeight, reader.settings.lineWidth, reader.settings.fontFamily,
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
    const rtl = reader.view.book?.dir === 'rtl'
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
    const r = reader.view?.renderer
    if (!r || !numberStrip.childElementCount) return
    const delta = r.start - stripStart
    const rtl = reader.view.book?.dir === 'rtl'
    numberStrip.style.transform = `translateX(${rtl ? delta : -delta}px)`
}

export { followScroll, updatePageNumbers }
