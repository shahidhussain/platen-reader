// Platen Reader: help for VoiceOver.
//
// The book is shown in a web view, so VoiceOver meets it as "web content".
// Two things make that friendlier:
//
// - Names. The page and each chapter's frame are named after the book and
//   chapter, so VoiceOver says "The Trial, chapter 3" rather than an unnamed
//   web area or frame.
// - Following the page. In paginated mode the whole chapter is laid out side
//   by side and only one page is visible, so VoiceOver's cursor can be left
//   behind (or wander off-screen) when a page turns. While VoiceOver is on,
//   each page turn moves keyboard focus, which VoiceOver follows, to the
//   first paragraph on the new page; VoiceOver then reads from there.

import { reader } from './state.js'

let voiceOverOn = false
let bookTitle = ''
let focused = null

function setVoiceOver(on) {
    voiceOverOn = !!on
    if (!voiceOverOn) clearFocus()
}

// Names the web area after the book.
function nameBook(title) {
    bookTitle = title || ''
    if (bookTitle) document.title = bookTitle
    reader.view?.setAttribute('aria-label', bookTitle)
}

// Names a chapter's frame, e.g. "The Trial, Chapter 3".
function nameSection(doc, chapter) {
    const frame = doc?.defaultView?.frameElement
    if (!frame) return
    const name = [bookTitle, chapter].filter(Boolean).join(', ')
    frame.setAttribute('title', name)
    frame.setAttribute('aria-label', name)
}

function clearFocus() {
    if (!focused) return
    focused.removeAttribute('tabindex')
    focused.removeAttribute('data-platen-reading')
    focused = null
}

// Paragraph-like elements that VoiceOver reads as one piece.
const blocks = 'p, h1, h2, h3, h4, h5, h6, li, blockquote, dd, dt, figcaption, pre, td, th, div'

// Called after the view moves (a page turn, a jump). Moves focus to the
// first paragraph that starts or continues on the page now on screen.
function followPage() {
    if (!voiceOverOn || reader.isFixedLayout) return
    const range = reader.view?.lastLocation?.range
    let node = range?.startContainer
    if (!node) return
    if (node.nodeType !== Node.ELEMENT_NODE) node = node.parentElement
    const target = node?.closest?.(blocks) ?? node
    if (!target || target === focused) return
    clearFocus()
    target.setAttribute('tabindex', '-1')
    target.setAttribute('data-platen-reading', '')
    // preventScroll: the paragraph may have begun on the previous page;
    // focusing it must not move the page back.
    target.focus({ preventScroll: true })
    focused = target
}

export { followPage, nameBook, nameSection, setVoiceOver }
