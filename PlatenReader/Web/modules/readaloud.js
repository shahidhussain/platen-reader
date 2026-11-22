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
//   chapter, or a later page) and it is highlighted as a foliate annotation
//   (drawn on foliate's overlay, as search results are, so the book's own
//   markup is never changed; the CSS Highlight API left stale marks behind
//   in WebKit's column layout).
// - `stop` takes the highlight away.

import { reader } from './state.js'
import { post } from './bridge.js'
import { TTS } from '../foliate/tts.js'
import { textWalker } from '../foliate/text-walker.js'
import { Overlayer } from '../foliate/overlayer.js'

// Sentences sent for each request.
const BATCH = 20
// The highlight's colour: the accent, at the overlay's usual opacity.
const COLOUR = '#f08c1e'

let active = false
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
        if (e.detail.annotation?.platenReadAloud) e.detail.draw(Overlayer.highlight, { color: COLOUR })
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

// Sends about BATCH sentences, or what is left of the book.
async function sendMore(fromRange) {
    let sent = 0
    while (active && sent < BATCH) {
        const ssml = await nextSSML(fromRange)
        fromRange = null
        if (!ssml) { if (active) post('readAloudEnd'); return }
        const block = parseBlock(ssml)
        const ranges = rangesOf(cursor.tts, block.sentences.map(s => s.mark).filter(m => m != null))
        const sentences = block.sentences
            .filter(s => s.text && /[\p{L}\p{N}]/u.test(s.text))
            .map(s => {
                const range = ranges.get(s.mark)
                let cfi = null
                try { cfi = range ? reader.view.getCFI(cursor.index, range) : null } catch {}
                return { mark: cfi, text: s.text }
            })
        if (!sentences.length) continue
        post('readAloudBlock', { lang: block.lang, sentences })
        sent += sentences.length
    }
}

// Begins at the first sentence on the current page.
async function start() {
    active = true
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

// Swift is starting to speak the sentence at `cfi`: show it.
let marking = Promise.resolve()
function mark(cfi) {
    if (!active || !cfi) return
    // One at a time, in order (turning to another chapter takes a moment).
    marking = marking.then(() => show(cfi)).catch(() => {})
}

async function show(cfi) {
    if (!active) return
    const { index, anchor } = reader.view.resolveCFI(cfi)
    let shown = onScreen()
    if (shown?.index !== index) {
        await reader.view.goTo(cfi)
        shown = onScreen()
    }
    if (!shown?.doc || shown.index !== index) return
    listenForDrawing()
    clearHighlight()
    highlighted = { value: cfi, platenReadAloud: true }
    await reader.view.addAnnotation(highlighted)
    // To the page holding the sentence, if it is not already showing.
    const range = anchor(shown.doc)
    if (range) reader.view.renderer.scrollToAnchor?.(range, true)
}

function stop() {
    active = false
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

export const readAloud = { start, more, mark, stop, parseBlock, preview }
