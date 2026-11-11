// Platen Reader: help for VoiceOver.
//
// The book is shown in a web view, so VoiceOver meets it as web content,
// and in paginated mode the whole chapter is laid out side by side with only
// one page visible. Reading by moving VoiceOver's cursor through that is
// awkward, and the cursor easily wanders onto a page that is not showing.
// So, while VoiceOver is on:
//
// - Each time the page changes, the text now on screen is sent to Swift,
//   which asks VoiceOver to read it out (an accessibility announcement).
//   Turning the page reads the next one; R reads the current page again.
// - VoiceOver's cursor is left alone. (Moving it to the new page made
//   VoiceOver scroll back to wherever that paragraph began, which turned
//   the page back.)
//
// The page and each chapter's frame are also named after the book and the
// chapter, so VoiceOver says "Legend, Prologue" rather than "web area".

import { reader } from './state.js'
import { post } from './bridge.js'

let voiceOverOn = false
let bookTitle = ''
let lastRead = null

function setVoiceOver(on) {
    voiceOverOn = !!on
    lastRead = null
}

// Names the web area after the book.
function nameBook(title) {
    bookTitle = title || ''
    if (bookTitle) document.title = bookTitle
    reader.view?.setAttribute('aria-label', bookTitle)
}

// Names a chapter's frame, e.g. "Legend, Prologue".
function nameSection(doc, chapter) {
    const frame = doc?.defaultView?.frameElement
    if (!frame) return
    const name = [bookTitle, chapter].filter(Boolean).join(', ')
    frame.setAttribute('title', name)
    frame.setAttribute('aria-label', name)
}

// The text on screen: the visible range foliate reports (both pages in a
// two-page spread), with runs of white space collapsed.
const visibleText = () =>
    (reader.view?.lastLocation?.range?.toString() ?? '').replace(/\s+/g, ' ').trim()

// Called after every move. Reads the new page, unless this was only a
// re-layout ("anchor": the same text, laid out again) or the same page.
function pageChanged(reason) {
    if (!voiceOverOn || reason === 'anchor') return
    const cfi = reader.view?.lastLocation?.cfi
    if (!cfi || cfi === lastRead) return
    lastRead = cfi
    readPage()
}

// Asks VoiceOver (through Swift) to read the page on screen.
function readPage() {
    const text = visibleText()
    if (text) post('readAloud', { text })
}

export { nameBook, nameSection, pageChanged, readPage, setVoiceOver }
