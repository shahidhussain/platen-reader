// Platen Reader: help for VoiceOver.
//
// The book is shown in a web view, which VoiceOver would announce as "web
// content", and in paginated mode the whole chapter is laid out side by
// side with only one page visible. So VoiceOver never sees the web view:
// Swift hides it and puts a native "page" in its place (see
// BookPageAccessibilityView), holding exactly the text on screen.
//
// - Each time the page changes, the text now on screen is sent to Swift
//   ('pageText'), which puts it on that page. While VoiceOver is on and the
//   page has just turned (not merely been laid out again), `speak` asks
//   VoiceOver to read it out at once. R reads the current page again.
// - VoiceOver's cursor is left alone. (Moving it to the new page made
//   VoiceOver scroll back to wherever that paragraph began, which turned
//   the page back.)
//
// The page and each chapter's frame are also named after the book and the
// chapter, for anything else that looks inside the web view.

import { reader } from './state.js'
import { post } from './bridge.js'

let voiceOverOn = false
let bookTitle = ''
let lastRead = null

function setVoiceOver(on) {
    voiceOverOn = !!on
    lastRead = null
    // Fill in the page straight away, without reading it out.
    if (voiceOverOn) sendPage(false)
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

// Called after every move. Updates the page VoiceOver sees, and reads it
// out unless this was only a re-layout ("anchor": the same text, laid out
// again) or the same page as last time.
// The page is kept up to date even with VoiceOver off, for other tools
// that read the screen (Voice Control, Switch Control, VoiceOver turned on
// later); it is only read out while VoiceOver is on.
function pageChanged(reason) {
    const cfi = reader.view?.lastLocation?.cfi
    const turned = reason !== 'anchor' && !!cfi && cfi !== lastRead
    if (turned) lastRead = cfi
    sendPage(voiceOverOn && turned)
}

// Asks VoiceOver (through Swift) to read the page on screen.
function readPage() {
    sendPage(true)
}

function sendPage(speak) {
    post('pageText', { text: visibleText(), speak })
}

export { nameBook, nameSection, pageChanged, readPage, setVoiceOver }
