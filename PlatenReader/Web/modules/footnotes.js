// Platen Reader: footnotes and endnotes in a pop-up (spec, "Interaction
// model": a click or tap on a note reference shows the note; a click
// elsewhere or Esc closes it).
//
// A link counts as a note reference when the book marks it as one (EPUB
// `epub:type="noteref"` or ARIA `role="doc-noteref"`), or when it looks like
// one: a superscript link that is not a back-link. These rules follow
// foliate-js's footnotes.js (MIT), which Platen does not use directly: it
// renders each note by opening the book a second time.
//
// The note is taken from its section's document and shown in the shell,
// beside the reference, in the theme's colours. Nothing in it can run: the
// shell's Content-Security-Policy allows no inline scripts or handlers.

import { reader } from './state.js'
import { post } from './bridge.js'

const typesOf = el => new Set(el?.getAttributeNS?.('http://www.idpf.org/2007/ops', 'type')?.split(' '))
const rolesOf = el => new Set(el?.getAttribute?.('role')?.split(' '))

const isSuperscript = el => {
    if (!el) return false
    if (el.matches('sup')) return true
    const align = el.ownerDocument.defaultView.getComputedStyle(el).verticalAlign
    return align === 'super' || align === 'top' || align === 'text-top' || /^\d/.test(align)
}

const isNoteReference = a => {
    const types = typesOf(a), roles = rolesOf(a)
    if (types.has('noteref') || roles.has('doc-noteref')) return true
    if (types.has('backlink') || roles.has('doc-backlink')) return false
    return isSuperscript(a) || (a.children.length === 1 && isSuperscript(a.children[0])) || isSuperscript(a.parentElement)
}

// The element holding the note: the target itself when it is a block (an
// aside, list item or paragraph), else its nearest block ancestor.
const inline = 'a, span, sup, sub, em, strong, i, b, small, big'
const noteElement = target => {
    let el = target
    while (el && el.matches(inline) && el.parentElement && el.parentElement !== el.ownerDocument.body) el = el.parentElement
    if (el === el?.ownerDocument.body) return target.nextElementSibling ?? target
    return el
}

let popup = null
let openedAt = 0

const close = () => {
    if (!popup) return false
    popup.remove()
    popup = null
    post('note', { open: false })
    return true
}

const isOpen = () => !!popup

// Shows the note for a link, near `rect` (the link's place in the window).
async function show(href, rect) {
    const book = reader.view.book
    const { index, anchor } = await book.resolveHref(href)
    const doc = await book.sections[index].createDocument()
    const target = anchor(doc)
    if (!target) throw new Error('note not found')
    const el = noteElement(target)
    const content = document.importNode(el, true)
    // Back-links ("↩") lead back to where the reader already is.
    content.querySelectorAll('a').forEach(a => {
        const t = typesOf(a), r = rolesOf(a)
        if (t.has('backlink') || r.has('doc-backlink') || /^\s*[↩↑]\s*$/.test(a.textContent)) a.remove()
        else a.removeAttribute('href') // links inside the note go nowhere
    })
    // Pictures would need the book's own resource URLs; text is what matters.
    content.querySelectorAll('img, svg, video, audio, script, style, link').forEach(n => n.remove())

    close()
    const s = reader.settings
    popup = document.createElement('div')
    popup.id = 'platen-note'
    popup.setAttribute('role', 'dialog')
    popup.setAttribute('aria-label', 'Note')
    popup.style.cssText = `
        position: fixed; z-index: 20; box-sizing: border-box;
        max-width: min(440px, calc(100vw - 32px)); max-height: 40vh; overflow: auto;
        padding: 14px 18px; border-radius: 12px;
        background: ${s?.theme?.background ?? '#fff'}; color: ${s?.theme?.foreground ?? '#000'};
        border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
        box-shadow: 0 8px 28px rgba(0, 0, 0, ${s?.theme?.dark ? 0.6 : 0.18});
        font: ${Math.round((s?.fontSize ?? 18) * 0.85)}px/1.45 ${s?.fontFamily ? `"${s.fontFamily}", serif` : 'Georgia, serif'};
        -webkit-user-select: text; user-select: text;`
    popup.append(...(el.matches('aside, li, div, section') ? content.childNodes : [content]))
    document.body.append(popup)

    // Below the reference if it fits, else above; kept inside the window.
    const box = popup.getBoundingClientRect()
    const below = rect.bottom + 8
    const top = below + box.height <= window.innerHeight - 16 ? below : Math.max(16, rect.top - 8 - box.height)
    const left = Math.min(Math.max(16, rect.left + rect.width / 2 - box.width / 2), window.innerWidth - 16 - box.width)
    popup.style.top = `${top}px`
    popup.style.left = `${left}px`
    openedAt = performance.now()
    post('note', { open: true })
}

// True just after a note opened: the tap that opened it must not close it
// (on iOS, Swift asks about a tap a moment after the page has handled it).
const justOpened = () => performance.now() - openedAt < 500

// foliate-js's "link" event: returns true if the link was a note reference
// and its note is being shown (so it must not be followed).
const handleLink = e => {
    const { a, href } = e.detail
    if (!a || !isNoteReference(a)) return false
    e.preventDefault()
    // The link's place in the window (its frame may be scrolled or scaled).
    const frame = a.ownerDocument.defaultView.frameElement
    const f = frame.getBoundingClientRect()
    const scale = frame.offsetWidth ? f.width / frame.offsetWidth : 1
    const r = a.getBoundingClientRect()
    const rect = { left: f.left + r.left * scale, top: f.top + r.top * scale,
                   width: r.width * scale, height: r.height * scale, bottom: f.top + r.bottom * scale }
    show(href, rect).catch(err => {
        // Not a note after all, or it could not be read: follow the link.
        post('log', { message: `note: ${err}; following the link` })
        reader.view.goTo(href)
    })
    return true
}

// A click in the shell outside the note closes it.
document.addEventListener('click', e => {
    if (popup && !popup.contains(e.target)) close()
}, true)

export { handleLink as handleNoteLink, close as closeNote, isOpen as isNoteOpen, justOpened as noteJustOpened }
