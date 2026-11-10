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

export { ensureReadableColours, fitWideTables, rescalePublisherFontSizes }
