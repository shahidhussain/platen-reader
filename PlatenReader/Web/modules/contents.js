// Platen Reader: The table of contents, and one built from headings when a book has none.

import { reader } from './state.js'
import { post } from './bridge.js'

// ---------------------------------------------------------------------------
// Location reporting

const flattenTOC = (items, depth = 0, out = []) => {
    for (const item of items ?? []) {
        out.push({ label: (item.label ?? '').trim(), href: item.href ?? '', depth })
        if (item.subitems?.length) flattenTOC(item.subitems, depth + 1, out)
    }
    return out
}


// ---------------------------------------------------------------------------
// Contents
//
// Books without a table of contents get one built from their sections'
// first headings. Each section also gets a chapter label, used by the
// slider while dragging and for books without a contents list.

async function synthesiseContents(book) {
    const items = []
    for (const section of book.sections) {
        if (section.linear === 'no' || !section.createDocument) continue
        try {
            const doc = await section.createDocument()
            const heading = doc.querySelector('h1, h2, h3, h4, h5, h6')
            const text = (heading?.textContent || doc.title || '').replace(/\s+/g, ' ').trim()
            items.push({ label: text || `Section ${items.length + 1}`, href: section.id, depth: 0 })
        } catch { /* unreadable section: leave it out */ }
    }
    return items
}

async function sendContents(book) {
    let toc = flattenTOC(book.toc)
    const synthesised = !toc.length
    if (synthesised) toc = await synthesiseContents(book)
    const byHref = new Map(toc.map(t => [t.href, t.label]))
    let last = ''
    const sectionLabels = book.sections.map((section, i) => {
        const label = synthesised ? byHref.get(section.id) : reader.view.getProgressOf(i)?.tocItem?.label?.trim()
        if (label) last = label
        return last
    })
    post('contents', { toc, sectionLabels, synthesised })
}

export { sendContents }
