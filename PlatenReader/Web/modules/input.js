// Platen Reader: Clicks, pictures, selection and trackpad swipes inside book pages.

import { reader } from './state.js'
import { ribbons } from './bookmarks.js'
import { post } from './bridge.js'

// ---------------------------------------------------------------------------
// Pointer input inside book documents

// A "click" is mouse-down and mouse-up with negligible movement. The zone is
// computed in window coordinates and sent to Swift, which decides what to do
// (turn a page or toggle the overlay), so behaviour lives in one place.
//
// The side zones are wider than the centre: most clicks are page turns.
const sideZoneFraction = 0.38

// A press held this long is a long press or a Force Touch (Look Up), not a
// click: acting on it would dismiss the Look Up panel it opened.
const longPressMs = 450

// Images smaller than this (icons, ornaments, drop caps) are not zoomable.
const minZoomableSize = 48

const attachPointerHandlers = (doc, index) => {
    let down = null
    doc.addEventListener('mousedown', e => {
        const selection = doc.getSelection()
        down = { x: e.screenX, y: e.screenY, t: e.timeStamp, forced: false,
                 hadSelection: selection && !selection.isCollapsed }
    })
    // WebKit's Force Touch events: a firm press opens Look Up.
    for (const type of ['webkitmouseforcewillbegin', 'webkitmouseforcedown'])
        doc.addEventListener(type, () => { if (down) down.forced = true })
    doc.addEventListener('click', e => {
        if (e.button !== 0 || e.detail > 1 || !down) return // part of a double/triple click
        if (down.hadSelection) return // the click just dismissed a selection
        if (down.forced || e.timeStamp - down.t > longPressMs) return
        if (Math.hypot(e.screenX - down.x, e.screenY - down.y) > 4) return // a drag
        if (e.target.closest?.('a[href], audio, video, button, input, select, textarea, label')) return
        if (e.defaultPrevented) return

        // Convert from the iframe's coordinates to the window's. The iframe
        // may be scrolled (paginated mode) or scaled (fixed layout).
        const frame = doc.defaultView.frameElement
        const rect = frame.getBoundingClientRect()
        const scale = frame.offsetWidth ? rect.width / frame.offsetWidth : 1

        // A click on a picture opens it full size (not in fixed layout, where
        // the whole page is usually one picture).
        const img = !reader.isFixedLayout && e.target.closest?.('img')
        if (img) {
            const r = img.getBoundingClientRect()
            if (r.width * scale >= minZoomableSize && r.height * scale >= minZoomableSize) {
                zoomImage(img, {
                    x: rect.left + r.left * scale, y: rect.top + r.top * scale,
                    width: r.width * scale, height: r.height * scale,
                })
                return
            }
        }

        const x = rect.left + e.clientX * scale
        const side = window.innerWidth * sideZoneFraction
        const zone = x < side ? 'left' : x > window.innerWidth - side ? 'right' : 'centre'
        post('click', { zone })
    })
    // Context menus are WebKit's own (Look Up, Translate, Copy, Share…);
    // Swift adds Platen's items, using the selection reported here.
    let selectionTimer
    doc.addEventListener('selectionchange', () => {
        clearTimeout(selectionTimer)
        selectionTimer = setTimeout(() => reportSelection(doc, index), 120)
    })
}

// Sends a picture's bytes and on-screen position to Swift, which shows it
// full size (with Copy and Save) in a native view. The image's src is a
// blob: URL made by foliate-js, so reading it stays inside the page.
async function zoomImage(img, rect) {
    try {
        const blob = await (await fetch(img.currentSrc || img.src)).blob()
        // Base64, built in chunks (String.fromCharCode has an argument limit).
        const bytes = new Uint8Array(await blob.arrayBuffer())
        let binary = ''
        for (let i = 0; i < bytes.length; i += 0x8000)
            binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
        post('image', { data: btoa(binary), mimeType: blob.type, alt: img.alt ?? '', rect })
    } catch (e) {
        post('log', { level: 'error', message: `image zoom failed: ${e}` })
    }
}

// Tells Swift what is selected, with the chapter and printed page it is on,
// for Copy with Citation and "Search Book for …".
const reportSelection = (doc, index) => {
    const selection = doc.getSelection()
    const text = selection?.toString().trim() ?? ''
    if (!text || !selection.rangeCount) return post('selection', { text: '' })
    const range = selection.getRangeAt(0)
    const { tocItem, pageItem } = reader.view.getProgressOf(index, range) ?? {}
    post('selection', {
        text,
        chapter: tocItem?.label?.trim() ?? '',
        page: pageItem?.label ?? null,
    })
}


// ---------------------------------------------------------------------------
// Trackpad swipes (paginated mode)
//
// Swift reads the trackpad gesture natively, where it can tell when the
// fingers touch and lift and can ignore momentum, and sends it here: the
// page follows the fingers, then settles on the next page or springs back.
// One gesture never moves more than one page. Vertical scrolling and mouse
// wheels are turned into single page turns in Swift.

const swipe = {
    move(dx) {
        if (!reader.view || reader.isFixedLayout) return
        ribbons.hidden = true // they would not move with the page
        reader.view.renderer.scrollBy?.(dx, 0)
    },
    // direction: 1 or -1 for a flick, which turns the page however short
    // it was; 0 to settle on whichever page is mostly in view.
    end(direction) {
        if (!reader.view || reader.isFixedLayout) return
        // A swipe always settles with a slide, whatever the page-turn
        // setting (unless Reduce Motion is on).
        const r = reader.view.renderer
        const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches
        const animated = r.hasAttribute('animated')
        if (!reduceMotion) r.setAttribute('animated', '')
        r.snap?.(direction, 0)
        if (!animated) setTimeout(() => {
            if (!(reader.settings?.animated)) r.removeAttribute('animated')
        }, 400)
        ribbons.hidden = false
    },
}

export { attachPointerHandlers, swipe }
