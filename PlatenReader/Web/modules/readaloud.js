// Platen Reader: the text for read aloud, and the sentence being read.
//
// Swift owns the speech (BookSession, ReadAloudController, a SpeechEngine);
// this module only supplies the text and shows where reading has got to.
//
// - Text. foliate's TTS (foliate/tts.js) splits a chapter into blocks
//   (paragraphs, headings) and marks each sentence. `start` begins at the
//   first sentence on the current page; each call of `more` sends Swift the
//   next blocks ('readAloudBlock': a block's language and its sentences),
//   about `BATCH` sentences at a time, carrying on into the following
//   chapters, and says 'readAloudEnd' at the end of the book.
// - Reading ahead. iOS suspends the web view once the app is in the
//   background, even while it plays audio, so Swift keeps a long queue of
//   sentences in hand (asking for more while plenty remain), and chapters
//   after the one on screen are read from documents loaded off screen
//   (`section.createDocument()`): reading carries on at the lock screen
//   for many minutes, and the queue is topped up whenever the app is open.
// - Marks. Each sentence is sent with its CFI, foliate's location of it,
//   which holds whatever chapter it is in. `mark(cfi)` is called as Swift
//   starts speaking the sentence: the page turns to it if needed (another
//   chapter, or a later page). `word(cfi, start, length)` follows for each
//   word (Apple's voices report them), and the word being read is
//   underlined: a thin line, not a highlight, which looked too heavy and
//   means something else in a book (the reader asked, 22 Nov 2026). Without
//   word timing the whole sentence is underlined instead. Underlines are
//   foliate annotations, drawn on its overlay as search results are, so the
//   book's own markup is never changed (the CSS Highlight API left stale
//   marks behind in WebKit's column layout).
// - `stop` takes the underline away.

import { reader } from './state.js'
import { post } from './bridge.js'
import { TTS } from '../foliate/tts.js'
import { textWalker } from '../foliate/text-walker.js'
import { Overlayer } from '../foliate/overlayer.js'

// Sentences sent for each request.
const BATCH = 20
// The underline: the accent colour, thin.
const COLOUR = '#f08c1e'
const WIDTH = 2
// How long to wait for the first word before underlining the whole
// sentence instead (an engine without word timing).
const WORD_WAIT = 600

let active = false
// Whether the page follows the voice (turns to the sentence and word being
// read). Off from the moment the reader moves the page themselves until
// reading starts again from there: following on turned the page straight
// back to the sentence still being spoken, and the page turn that met it
// halfway went wrong ("End of book"; the reader saw both, 24 Nov 2026).
let following = true
// Where the text has got to: the section being read ahead, its document and
// its TTS. (Not necessarily the section on screen.)
let cursor = null
// The sentence highlighted now, as a foliate annotation.
let highlighted = null
let drawing = false

// foliate asks how to draw each annotation; ours are the read-aloud one.
function listenForDrawing() {
    if (drawing || !reader.view) return
    drawing = true
    reader.view.addEventListener('draw-annotation', e => {
        if (e.detail.annotation?.platenReadAloud) e.detail.draw(Overlayer.underline, { color: COLOUR, width: WIDTH })
    })
}

function clearHighlight() {
    if (highlighted) reader.view?.deleteAnnotation(highlighted)
    highlighted = null
}

// The sentences in a block of SSML from foliate: the text after each
// <mark name="…"/> up to the next. A passage in another language is a
// <lang xml:lang="…"> inside the block, so each sentence takes the language
// it sits in, and the block its first sentence's.
const XML_NS = 'http://www.w3.org/XML/1998/namespace'
function parseBlock(ssml) {
    const xml = new DOMParser().parseFromString(ssml, 'application/xml')
    const root = xml.documentElement
    const langOf = el => el.getAttributeNS(XML_NS, 'lang') || el.getAttribute('xml:lang') || null
    const sentences = []
    let current = null
    const walk = (node, lang) => {
        for (const child of node.childNodes) {
            if (child.nodeType === 1 && child.localName === 'mark') {
                current = { mark: child.getAttribute('name'), text: '', lang }
                sentences.push(current)
            } else if (child.nodeType === 3 || child.nodeType === 4) {
                if (!current) { current = { mark: null, text: '', lang }; sentences.push(current) }
                current.text += child.textContent
            } else if (child.nodeType === 1) {
                walk(child, langOf(child) ?? lang)
            }
        }
    }
    walk(root, langOf(root))
    const cleaned = sentences.map(s => ({ mark: s.mark, text: s.text.replace(/\s+/g, ' ').trim(), lang: s.lang }))
    const firstReal = cleaned.find(s => s.text && /[\p{L}\p{N}]/u.test(s.text))
    return { lang: firstReal?.lang ?? langOf(root), sentences: cleaned }
}

const onScreen = () => reader.view?.renderer?.getContents?.()?.[0]

// A cursor on section `index`: its document (the one on screen if it is
// showing, else one loaded off screen) and a TTS over it.
async function cursorAt(index) {
    const book = reader.view?.book
    const section = book?.sections?.[index]
    if (!section) return null
    const shown = onScreen()
    const doc = shown?.index === index ? shown.doc : await section.createDocument?.()
    if (!doc?.body) return null
    // The highlight function is swapped in and out to learn each sentence's
    // range (see `rangesOf`).
    const tts = new TTS(doc, textWalker, () => {}, 'sentence')
    return { index, doc, tts, started: false }
}

// Each mark's range in the block the TTS has just produced: foliate keeps
// them privately, but `setMark` hands a mark's range to the highlight
// function, so it is asked for each in turn.
function rangesOf(tts, marks) {
    const ranges = new Map()
    const original = tts.highlight
    for (const mark of marks) {
        tts.highlight = range => ranges.set(mark, range)
        tts.setMark(mark)
    }
    tts.highlight = original
    return ranges
}

// The next block of SSML from the cursor, moving into later sections at
// the end of each; null at the end of the book.
async function nextSSML(fromRange) {
    const count = reader.view?.book?.sections?.length ?? 0
    for (let guard = 0; guard < count + 1 && active && cursor; guard++) {
        let ssml
        if (!cursor.started) {
            cursor.started = true
            try { ssml = fromRange ? cursor.tts.from(fromRange) : cursor.tts.start() }
            catch { ssml = cursor.tts.start() }
            fromRange = null
        } else {
            ssml = cursor.tts.next()
        }
        if (ssml) return ssml
        // The end of this section: on to the next that has a document.
        let next = null
        for (let i = cursor.index + 1; i < count && !next; i++) next = await cursorAt(i)
        cursor = next
    }
    return null
}

// Reading from a page begins at its first word (the reader asked, 24 Nov
// 2026): foliate hands back the whole paragraph the page begins in, so its
// sentences that end before the page are left out, and the one that runs
// onto the page is cut to begin there. (Reading it from its start, on the
// page before, turned the page back.) `pageStart` is the page's start; the
// cut sentence's mark is the part on the page, so its words still line up.
function fromPage(sentence, range, pageStart) {
    if (!range || !pageStart || range.startContainer.ownerDocument !== pageStart.startContainer.ownerDocument)
        return { sentence, range }
    try {
        // (`pageStart` is collapsed to the page's first point: comparePoint
        // is -1 before it, 0 at it, 1 after it.)
        // Ends before the page: not read.
        if (pageStart.comparePoint(range.endContainer, range.endOffset) <= 0) return null
        // Begins before the page: only the part on it.
        if (pageStart.comparePoint(range.startContainer, range.startOffset) < 0) {
            const part = range.cloneRange()
            part.setStart(pageStart.startContainer, pageStart.startOffset)
            const text = part.toString().replace(/\s+/g, ' ').trim()
            if (!/[\p{L}\p{N}]/u.test(text)) return null
            return { sentence: { ...sentence, text }, range: part }
        }
    } catch {}
    return { sentence, range }
}

// Where to ask foliate to read from, for a page: the start of the block
// (paragraph) the page begins in. foliate's `from` begins at the first
// sentence that starts on the page, leaving out the one running onto it;
// from the paragraph's start, `fromPage` can cut that one to the page.
function paragraphStart(page) {
    const doc = page.startContainer.ownerDocument
    let node = page.startContainer
    if (node.nodeType !== 1) node = node.parentElement
    // (Not a div: books wrap whole chapters in one.)
    const block = node?.closest?.('p, li, blockquote, h1, h2, h3, h4, h5, h6, dd, dt, td, th, figcaption, pre')
    if (!block) return page
    const range = doc.createRange()
    range.setStart(block, 0)
    range.collapse(true)
    return range
}

// Sends about BATCH sentences, or what is left of the book. `page`: reading
// starts on this page (the first call only).
async function sendMore(page) {
    let sent = 0
    // The page's start, for the first block only (see `fromPage`).
    let pageStart = page ? page.cloneRange() : null
    if (pageStart) pageStart.collapse(true)
    let fromRange = page ? paragraphStart(page) : null
    while (active && sent < BATCH) {
        const ssml = await nextSSML(fromRange)
        fromRange = null
        if (!ssml) { if (active) post('readAloudEnd'); return }
        const block = parseBlock(ssml)
        const ranges = rangesOf(cursor.tts, block.sentences.map(s => s.mark).filter(m => m != null))
        const sentences = block.sentences
            .filter(s => s.text && /[\p{L}\p{N}]/u.test(s.text))
            .map(s => pageStart ? fromPage(s, ranges.get(s.mark), pageStart) : { sentence: s, range: ranges.get(s.mark) })
            .filter(x => x)
            .map(({ sentence, range }) => {
                let cfi = null
                try { cfi = range ? reader.view.getCFI(cursor.index, range) : null } catch {}
                return { mark: cfi, text: sentence.text }
            })
        // Until something on the page is found, every block is checked
        // against it (a page can begin after a whole paragraph has ended).
        if (!sentences.length) continue
        pageStart = null
        post('readAloudBlock', { lang: block.lang, sentences })
        sent += sentences.length
    }
}

// Begins at the first sentence on the current page.
async function start() {
    following = true
    active = true
    wordsComing = false
    clearHighlight()
    const shown = onScreen()
    cursor = shown ? await cursorAt(shown.index) : null
    if (!cursor) return post('readAloudEnd')
    return sendMore(reader.view.lastLocation?.range ?? null)
}

async function more() {
    if (!active || !cursor) return
    return sendMore(null)
}

// Swift is starting to speak the sentence at `cfi`: turn to it, and wait
// for its words; if none come, underline the whole sentence.
let marking = Promise.resolve()
let sentenceTimer = null
let currentSentence = null
let wordSeen = false
// Some word of this reading has been underlined: the voice reports words,
// so a sentence whose first word is slow to come (a pause after a quotation
// mark, the next sentence still being made) is not underlined whole in the
// meantime, which showed as a flash of the whole sentence.
let wordsComing = false

// The reader moved the page: stop following the voice (see `following`).
function hold() {
    following = false
    clearTimeout(sentenceTimer)
    clearHighlight()
}

function mark(cfi) {
    if (!active || !cfi || !following) return
    currentSentence = cfi
    wordSeen = false
    clearTimeout(sentenceTimer)
    // One at a time, in order (turning to another chapter takes a moment).
    marking = marking.then(() => showSentence(cfi)).catch(() => {})
    sentenceTimer = setTimeout(() => {
        if (active && !wordSeen && !wordsComing && currentSentence === cfi)
            marking = marking.then(() => underline(cfi)).catch(() => {})
    }, WORD_WAIT)
}

// A word is starting: `start` and `length` count UTF-16 units in the
// sentence's text as sent (its white space collapsed, as `sendMore` did).
function word(cfi, start, length) {
    if (!active || !cfi || !following) return
    wordSeen = true
    wordsComing = true
    clearTimeout(sentenceTimer)
    marking = marking.then(async () => {
        const shown = await showSentence(cfi)
        if (!shown) return
        const sentence = shown.anchor(shown.doc)
        const range = sentence && wordRange(sentence, start, length)
        if (!range) return underline(cfi)
        // Apple sometimes reports a lone comma or dash as a word: the
        // underline stays where it was.
        if (!/[\p{L}\p{N}]/u.test(range.toString())) return
        // The sentence may run over to the next page. (Without selecting
        // it: foliate's `true` here selects the word, which then showed as
        // a lasting selection instead of the underline.)
        if (!isOnScreen(range)) {
            // A word before the page (the start of a sentence that runs onto
            // it) is not chased back to: no underline until the voice
            // reaches the page. A word after it turns the page on.
            if (isBeforeScreen(range)) return clearHighlight()
            reader.view.renderer.scrollToAnchor?.(range)
        }
        return underline(reader.view.getCFI(shown.index, range))
    }).catch(() => {})
}

// The sentence's chapter and page on screen; its index, document and anchor.
async function showSentence(cfi) {
    if (!active || !following) return null
    const { index, anchor } = reader.view.resolveCFI(cfi)
    let shown = onScreen()
    if (shown?.index !== index) {
        clearHighlight()
        await reader.view.goTo(cfi)
        shown = onScreen()
    }
    if (!shown?.doc || shown.index !== index) return null
    const range = anchor(shown.doc)
    // Only a sentence with nothing of it on the page moves the page to it.
    // A sentence partly on screen stays put: reading started from a page
    // begins with the sentence that runs onto it from the page before, and
    // turning back to its start undid the reader's turn (24 Nov 2026).
    if (range && !overlapsScreen(range)) reader.view.renderer.scrollToAnchor?.(range)
    return { index, doc: shown.doc, anchor }
}

async function underline(cfi) {
    if (!active) return
    listenForDrawing()
    clearHighlight()
    highlighted = { value: cfi, platenReadAloud: true }
    await reader.view.addAnnotation(highlighted)
}

// Whether a range is on the page showing (it begins at or after the start
// of what is visible, and ends at or before its end).
function isOnScreen(range) {
    const visible = reader.view.lastLocation?.range
    if (!visible || visible.startContainer.ownerDocument !== range.startContainer.ownerDocument) return false
    return range.compareBoundaryPoints(Range.START_TO_START, visible) >= 0
        && range.compareBoundaryPoints(Range.END_TO_END, visible) <= 0
}

// Where a range lies against the page showing: -1 before it, 1 after it,
// 0 overlapping it; null if it is in another document.
function placeOnScreen(range) {
    const visible = reader.view.lastLocation?.range
    if (!visible || visible.startContainer.ownerDocument !== range.startContainer.ownerDocument) return null
    try {
        if (visible.comparePoint(range.endContainer, range.endOffset) < 0) return -1
        if (visible.comparePoint(range.startContainer, range.startOffset) > 0) return 1
        return 0
    } catch { return null }
}
const overlapsScreen = range => placeOnScreen(range) === 0
const isBeforeScreen = range => placeOnScreen(range) === -1

// The part of `sentence` from `start` for `length` characters of its text
// with white space collapsed and trimmed, as it was sent to Swift.
function wordRange(sentence, start, length) {
    const doc = sentence.startContainer.ownerDocument
    const root = sentence.commonAncestorContainer
    const places = [] // each kept character's text node and offset
    let lastWasSpace = true // leading white space is trimmed
    const take = (node, from, to) => {
        const text = node.data
        for (let i = from; i < to; i++) {
            if (/\s/.test(text[i])) {
                if (!lastWasSpace) { places.push([node, i]); lastWasSpace = true }
            } else {
                places.push([node, i])
                lastWasSpace = false
            }
        }
    }
    if (root.nodeType === Node.TEXT_NODE) {
        take(root, sentence.startOffset, sentence.endOffset)
    } else {
        const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT)
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            if (!sentence.intersectsNode(n)) continue
            const from = n === sentence.startContainer ? sentence.startOffset : 0
            const to = n === sentence.endContainer ? sentence.endOffset : n.data.length
            take(n, from, to)
        }
    }
    const first = places[start], last = places[start + length - 1]
    if (!first || !last) return null
    const range = doc.createRange()
    range.setStart(first[0], first[1])
    range.setEnd(last[0], last[1] + 1)
    return range
}

function stop() {
    active = false
    clearTimeout(sentenceTimer)
    cursor = null
    clearHighlight()
}

// For checks (scripts/corpus-cases.sh): what reading aloud would begin
// with on this page, without reading: the book's language, the first three
// blocks' own, and the first sentence ("book:en blocks:en,fr,en first:…").
function preview() {
    // The chapter on screen is loaded already, so this needs no waiting
    // (a check reads the answer at once).
    const shown = onScreen()
    if (!shown?.doc?.body) return 'none'
    const c = { tts: new TTS(shown.doc, textWalker, () => {}, 'sentence') }
    const range = reader.view.lastLocation?.range
    let ssml = null
    try { ssml = range ? c.tts.from(range) : c.tts.start() } catch { ssml = c.tts.start() }
    const langs = []
    let first = null
    for (let i = 0; i < 50 && ssml && langs.length < 3; i++) {
        const block = parseBlock(ssml)
        const sentence = block.sentences.find(s => s.text && /[\p{L}\p{N}]/u.test(s.text))
        if (sentence) {
            langs.push(block.lang ?? '')
            first ??= sentence.text.slice(0, 40)
        }
        ssml = c.tts.next()
    }
    const book = reader.view.book?.metadata?.language
    return `book:${Array.isArray(book) ? book[0] : book ?? ''} blocks:${langs.join(',')} first:${first ?? ''}`
}

// For checks: the first `count` sentences read aloud would speak from the
// start of the chapter on screen, joined by " | " (a hard-wrapped
// paragraph must come out as whole sentences, not one per line).
function sentences(count = 4) {
    const shown = onScreen()
    if (!shown?.doc?.body) return 'none'
    const tts = new TTS(shown.doc, textWalker, () => {}, 'sentence')
    const found = []
    let ssml = tts.start()
    for (let i = 0; i < 50 && ssml && found.length < count; i++) {
        for (const s of parseBlock(ssml).sentences) {
            if (s.text && /[\p{L}\p{N}]/u.test(s.text) && found.length < count) found.push(s.text)
        }
        ssml = tts.next()
    }
    return 'sentences: ' + found.join(' | ')
}

// For checks: how the first block read from the page on screen compares
// with the page's start (each sentence: its start and end against it, and
// what would be read of it).
function probeStart() {
    const shown = onScreen()
    const page = reader.view.lastLocation?.range
    if (!shown?.doc || !page) return 'none'
    const tts = new TTS(shown.doc, textWalker, () => {}, 'sentence')
    const ssml = tts.from(paragraphStart(page))
    const block = parseBlock(ssml)
    const ranges = rangesOf(tts, block.sentences.map(x => x.mark).filter(m => m != null))
    const start = page.cloneRange()
    start.collapse(true)
    return 'probe ' + block.sentences.slice(0, 4).map(x => {
        const r = ranges.get(x.mark)
        if (!r) return 'no range: ' + x.text.slice(0, 20)
        const a = start.comparePoint(r.startContainer, r.startOffset)
        const b = start.comparePoint(r.endContainer, r.endOffset)
        const kept = fromPage(x, r, start)
        return `[${a},${b}] ${x.text.slice(0, 20)} -> ${kept ? kept.sentence.text.slice(0, 20) : 'dropped'}`
    }).join(' | ')
}

export const readAloud = { start, more, mark, word, stop, hold, parseBlock, preview, sentences, probeStart }
