// Platen Reader: Reader settings turned into CSS and paginator layout.

import { reader } from './state.js'
import { applyBodyTextSize, applyJustification } from './bookfixes.js'

// ---------------------------------------------------------------------------
// Settings → CSS and layout


// Approximate characters per line for each line-width setting. Medium,
// the default, is a classic book measure (60 to 75 characters is the
// comfortable range); Narrow is a little shorter, Wide a little longer. A
// wider window gets two columns (Two Pages), not longer lines.
const lineWidthChars = { narrow: 58, medium: 68, wide: 80 }
// Average glyph width as a fraction of font size, for typical book faces
// (measured: a Times-like face sets about 2.4 characters per em of line,
// spaces and punctuation included).
const charWidthEm = 0.42
// Show two pages when each column can hold a readable line (the spec asks
// for about 50 characters; a little more, as two cramped columns read
// worse than one comfortable one).
const minCharsForTwoColumns = 55

const bookCSS = s => `
    /* platen-styles (reader.js skips this sheet when rescaling font sizes) */
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color-scheme: ${s.theme.dark ? 'dark' : 'light'};
        font-size: ${s.fontSize}px !important;
        /* iOS enlarges text it judges too small for a wide block, and a
           chapter laid out as pages is one very wide block of columns, so
           the text size could change on switching to scrolling and back.
           The size chosen is the size shown. */
        -webkit-text-size-adjust: none !important;
        text-size-adjust: none !important;
    }
    html, body {
        background-color: ${s.transparent ? 'transparent' : s.theme.background} !important;
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

// The smallest margin at each side, as a share of the window: the shell's
// default, or what iOS asks for (in points, clear of rounded corners).
const minimumGap = s => s.sideMargin ? s.sideMargin / Math.max(window.innerWidth, 1) : 0.06

// The width of each column of text that foliate lays out, for a window
// `w` wide, `columns` columns and a side margin `g` (a share of the
// window): foliate pads the page by g/2 at each side and puts a gap of g·w
// between and around the columns (paginator.js, #beforeRender), so the
// text gets w·(1 − (columns + 1)·g) in all.
const columnWidth = (w, columns, g) => w * (1 - (columns + 1) * g) / columns

const columnCount = s => {
    if (s.flow === 'scrolled') return 1
    if (s.pageLayout === 'one') return 1
    // Two pages, side by side when each can hold a readable line (about
    // 55 characters); a narrower window falls back to one page.
    const w = window.innerWidth
    return columnWidth(w, 2, minimumGap(s)) >= minCharsForTwoColumns * s.fontSize * charWidthEm ? 2 : 1
}

const applyLayout = () => {
    const r = reader.view?.renderer
    if (!r || !reader.settings) return
    // iOS ambient light: no background, so the glow behind the page shows.
    document.documentElement.style.setProperty('--platen-bg',
        reader.settings.transparent ? 'transparent' : reader.settings.theme.background)
    document.documentElement.style.setProperty('--platen-fg', reader.settings.theme.foreground)
    const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches
    r.toggleAttribute('animated', reader.settings.animated && !reduceMotion)
    // iOS draws swipes natively (PageTurnAnimator in the iOS app), so
    // foliate must not also drag the page with the finger.
    r.toggleAttribute('native-swipe', !!reader.settings.nativeSwipe)
    if (reader.isFixedLayout) return

    // The measure: no line longer than the line-width setting allows
    // (about 68 characters at Medium). foliate itself stretches a column
    // across whatever room there is, so the side margins grow until each
    // column is that wide; they never shrink below the minimum.
    const w = Math.max(window.innerWidth, 1)
    const columns = columnCount(reader.settings)
    const measure = lineWidthChars[reader.settings.lineWidth] * reader.settings.fontSize * charWidthEm
    const fit = (1 - columns * measure / w) / (columns + 1)
    const gap = Math.max(minimumGap(reader.settings), fit)
    r.setAttribute('flow', reader.settings.flow)
    r.setAttribute('max-column-count', columns)
    // foliate shows as many columns as fit this size (up to the count
    // above); scrolling uses it as a cap on the page. Either way the margins
    // now decide the width, so it only has to allow the columns wanted.
    r.setAttribute('max-inline-size', `${Math.floor(columns === 1 ? w : w * (1 - gap) / 2 - 1)}px`)
    // In paginated mode the top margin leaves room for the bookmark ribbon
    // below the (hidden) title bar. iOS sends its own margins (in points):
    // above and below, clear of the Dynamic Island and home indicator.
    const { verticalMargin } = reader.settings
    r.setAttribute('margin', verticalMargin ? `${Math.round(verticalMargin)}px`
        : reader.settings.flow === 'scrolled' ? '44px' : '60px')
    r.setAttribute('gap', `${(gap * 100).toFixed(2)}%`)
    r.setStyles?.(bookCSS(reader.settings))
    // Each chapter's root, adjusted so its body text is the size chosen
    // (bookfixes.js), follows a change of size.
    // So do justified paragraphs, with Justify Text.
    for (const { doc } of r.getContents?.() ?? []) {
        if (!doc) continue
        applyBodyTextSize(doc, reader.settings.fontSize)
        applyJustification(doc, reader.settings.justify !== false)
    }
}

// Debounce re-layout during window resizes so dragging stays smooth; the
// paginator itself keeps the same text anchored in view.
let resizeTimer
window.addEventListener('resize', () => {
    clearTimeout(resizeTimer)
    resizeTimer = setTimeout(applyLayout, 100)
})

export { applyLayout }
