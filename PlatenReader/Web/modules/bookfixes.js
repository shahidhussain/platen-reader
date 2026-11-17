// Platen Reader: Fixes applied to each section of a book as it loads: unreadable colours,
// publisher font sizes and tables wider than a page.

import { reader } from './state.js'

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
    if (!reader.settings || !doc?.body) return
    const win = doc.defaultView
    const pageBackground = hexColour(reader.settings.theme.background)
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
            el.style.setProperty('color', reader.settings.theme.foreground, 'important')
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


// The same text size setting gave different sizes in different books:
// it sets the size of each chapter's root element, but many books then size
// their body text relative to it (p { font-size: 0.8em }, body { font-size:
// 120% }). So the size most of a chapter's text actually comes out at is
// measured, and the root is set so that that text is the size chosen.
// Headings, notes and small print keep their proportions to it.

// The body text size as a share of the root's: the font size that the most
// characters of the chapter are set in. Measured once per chapter, when it
// loads (the root is then at the size chosen).
function measureBodyTextRatio(doc) {
    const root = parseFloat(getComputedStyle(doc.documentElement).fontSize)
    if (!root || !doc.body) return 1
    const counts = new Map()
    const sizes = new Map() // element → its font size, measured once
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)
    let seen = 0
    for (let node = walker.nextNode(); node && seen < 20000; node = walker.nextNode()) {
        const length = node.textContent.trim().length
        const el = node.parentElement
        if (!length || !el) continue
        let size = sizes.get(el)
        if (size === undefined) {
            size = Math.round(parseFloat(getComputedStyle(el).fontSize) * 2) / 2
            sizes.set(el, size)
        }
        counts.set(size, (counts.get(size) ?? 0) + length)
        seen += length
    }
    // Too little text to judge (a title page, a picture): leave it alone.
    if (seen < 200) return 1
    let best = root, most = 0
    for (const [size, count] of counts) if (count > most) { best = size; most = count }
    const ratio = best / root
    return Math.min(Math.max(ratio, 0.6), 1.6)
}

// Sets the chapter's root so its body text is `fontSize` pixels.
function applyBodyTextSize(doc, fontSize) {
    const ratio = doc.platenTextRatio ?? 1
    if (Math.abs(ratio - 1) < 0.03) {
        doc.documentElement.style.removeProperty('font-size')
        return
    }
    doc.documentElement.style.setProperty('font-size', `${+(fontSize / ratio).toFixed(2)}px`, 'important')
}

function normaliseBodyTextSize(doc, fontSize) {
    doc.platenTextRatio = measureBodyTextRatio(doc)
    applyBodyTextSize(doc, fontSize)
}

// A page that is just one picture (a cover, a plate, a page of a picture
// book) shows it as large as the page allows, touching its sides or its top
// and bottom, rather than at whatever size the book's CSS gave it. A chapter
// counts as one when it has a single picture and almost no text.
function fitLonePicture(doc) {
    const body = doc.body
    if (!body) return
    const pictures = body.querySelectorAll('img, svg')
    const text = (body.textContent ?? '').replace(/\s+/g, '')
    if (pictures.length !== 1 || text.length > 20) return
    doc.documentElement.classList.add('platen-lone-picture')
    const style = doc.createElement('style')
    style.textContent = `
        /* platen-styles: a page that is one picture (bookfixes.js). On iOS
           the picture is shown natively, full screen, and reader.js hides
           the page's own copy once it has been sent. */
        html.platen-lone-picture body,
        html.platen-lone-picture body * {
            margin-top: 0 !important; margin-bottom: 0 !important;
            padding-top: 0 !important; padding-bottom: 0 !important;
        }
        html.platen-lone-picture img,
        html.platen-lone-picture svg {
            display: block !important;
            width: 100% !important;
            height: 100vh !important;
            max-height: 100vh !important;
            object-fit: contain !important;
            margin: 0 auto !important;
            /* No backing: dark themes give pictures a light one, which here
               filled the whole box with grey bars. */
            background-color: transparent !important;
        }`
    doc.head?.append(style)
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

export { applyBodyTextSize, ensureReadableColours, fitLonePicture, fitWideTables, normaliseBodyTextSize, rescalePublisherFontSizes }
