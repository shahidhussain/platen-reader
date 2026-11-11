// Platen Reader: Reader settings turned into CSS and paginator layout.

import { reader } from './state.js'

// ---------------------------------------------------------------------------
// Settings → CSS and layout


// Approximate characters per line for each line-width setting.
// Narrow is a classic book measure; Wide lets text run much closer to the
// edges of a large window.
const lineWidthChars = { narrow: 66, medium: 80, wide: 120 }
// With two pages side by side: how much of each half of the window a page
// may use (the rest is margin and the gap at the spine).
const twoPageShare = { narrow: 0.72, medium: 0.86, wide: 1 }
// Average glyph width as a fraction of font size, for typical book faces.
const charWidthEm = 0.5
// Spec: show two pages when each column can hold about 50 characters.
const minCharsForTwoColumns = 50

const bookCSS = s => `
    /* platen-styles (reader.js skips this sheet when rescaling font sizes) */
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color-scheme: ${s.theme.dark ? 'dark' : 'light'};
        font-size: ${s.fontSize}px !important;
    }
    html, body {
        background-color: ${s.theme.background} !important;
        color: ${s.theme.foreground} !important;
    }
    a:link, a:visited { color: ${s.theme.link} !important; }
    ${s.lineHeight ? `
    p, li, blockquote, dd, div {
        line-height: ${s.lineHeight} !important;
    }` : ''}
    ${s.fontFamily ? `
    body, p, li, blockquote, dd, td, th, dt, div {
        font-family: "${s.fontFamily.replace(/"/g, '')}", serif !important;
    }
    code, pre, kbd, samp, tt, code *, pre * {
        font-family: ui-monospace, Menlo, monospace !important;
    }` : ''}
    p, li, blockquote, dd {
        -webkit-hyphens: ${s.hyphenate && s.flow === 'paginated' ? 'auto' : 'manual'};
        hyphens: ${s.hyphenate && s.flow === 'paginated' ? 'auto' : 'manual'};
        widows: 2;
        orphans: 2;
    }
    pre { white-space: pre-wrap !important; }
    /* The paragraph VoiceOver is reading (see accessibility.js) takes focus;
       it needs no focus ring. */
    [data-platen-reading]:focus { outline: none !important; }
    /* Nothing may be wider than a page: in paginated mode anything wider
       spills into the next column and is drawn over its text. */
    body * { max-width: 100% !important; box-sizing: border-box; }
    body { overflow-wrap: break-word; }
    img, svg, video, table { height: auto; }
    ${s.theme.dark ? `
    /* Dark line art on transparent backgrounds would vanish; give images a
       light backing so they stay legible. */
    img, svg image { background-color: #f2f2f2; }` : ''}
    /* Kobo KEPUBs wrap the whole book in fixed-size column containers meant
       for Kobo's own reader; they fight our pagination, so neutralise them. */
    div#book-columns, div#book-inner {
        column-count: auto !important; columns: auto !important;
        width: auto !important; height: auto !important;
        margin: 0 !important; padding: 0 !important;
        overflow: visible !important;
    }
    /* Footnote bodies are reached by following their links. */
    aside[epub|type~="footnote"], aside[epub|type~="endnote"],
    aside[epub|type~="note"], aside[epub|type~="rearnote"] {
        display: none;
    }
`

const columnCount = s => {
    if (s.flow === 'scrolled') return 1
    if (s.pageLayout === 'one') return 1
    // Two pages, side by side when each half of the window can hold a
    // readable line; a narrow window falls back to one page.
    const half = window.innerWidth / 2
    return half >= minCharsForTwoColumns * s.fontSize * charWidthEm * 1.15 ? 2 : 1
}

const applyLayout = () => {
    const r = reader.view?.renderer
    if (!r || !reader.settings) return
    document.documentElement.style.setProperty('--platen-bg', reader.settings.theme.background)
    document.documentElement.style.setProperty('--platen-fg', reader.settings.theme.foreground)
    const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches
    r.toggleAttribute('animated', reader.settings.animated && !reduceMotion)
    if (reader.isFixedLayout) return

    const columns = columnCount(reader.settings)
    const lineWidth = lineWidthChars[reader.settings.lineWidth] * reader.settings.fontSize * charWidthEm
    // Two pages: each page gets a share of half the window, so the three
    // widths stay distinct even when the character counts would all be
    // wider than the half (they still cap it on very large screens).
    const inline = columns === 2
        ? Math.min(lineWidth, window.innerWidth / 2 * twoPageShare[reader.settings.lineWidth])
        : lineWidth
    r.setAttribute('flow', reader.settings.flow)
    r.setAttribute('max-column-count', columns)
    r.setAttribute('max-inline-size', `${Math.round(inline)}px`)
    // In paginated mode the top margin leaves room for the bookmark ribbon
    // below the (hidden) title bar.
    r.setAttribute('margin', reader.settings.flow === 'scrolled' ? '44px' : '60px')
    r.setAttribute('gap', '6%')
    r.setStyles?.(bookCSS(reader.settings))
}

// Debounce re-layout during window resizes so dragging stays smooth; the
// paginator itself keeps the same text anchored in view.
let resizeTimer
window.addEventListener('resize', () => {
    clearTimeout(resizeTimer)
    resizeTimer = setTimeout(applyLayout, 100)
})

export { applyLayout }
