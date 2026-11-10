// Platen Reader: Jumps (contents, links, search, slider) and the Back button.

import { reader } from './state.js'
import { post } from './bridge.js'

// ---------------------------------------------------------------------------
// Jumps and the Back button
//
// After a jump (contents, link, bookmark, search, slider), the overlay offers
// "Back to p. 87" or "Back to Chapter 3". It stays until the reader moves on
// from the destination by turning a page.

let back = null          // { cfi, label }
let jumpStartedAt = 0

const describeLocation = () => {
    const l = reader.view?.lastLocation
    if (!l?.cfi) return null
    const page = l.pageItem?.label
    const chapter = l.tocItem?.label?.trim()
    const label = page ? `p. ${page}` : chapter || `${Math.round((l.fraction ?? 0) * 100)}%`
    return { cfi: l.cfi, label }
}

const rememberJumpOrigin = keepOrigin => {
    const origin = describeLocation()
    jumpStartedAt = performance.now()
    if (keepOrigin && back) return
    if (!origin) return
    back = origin
    post('back', { label: back.label })
}

async function jump(go, keepOrigin = false) {
    rememberJumpOrigin(keepOrigin)
    await go()
}

function goBack() {
    if (!back) return
    const target = back.cfi
    back = null
    post('back', { label: null })
    jumpStartedAt = performance.now()
    return reader.view.goTo(target)
}

// Called for every relocation with foliate's reason. Re-layouts ("anchor")
// and the jump's own arrival do not count as moving on.
function noteMovement(reason) {
    if (!back || reason === 'anchor') return
    if (performance.now() - jumpStartedAt < 700) return
    back = null
    post('back', { label: null })
}

export { goBack, jump, noteMovement, rememberJumpOrigin }
