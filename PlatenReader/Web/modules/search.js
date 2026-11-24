// Platen Reader: Find in book.

import { Overlayer } from '../foliate/overlayer.js'
import { reader } from './state.js'
import { post } from './bridge.js'

// ---------------------------------------------------------------------------
// Find in book

let searchToken = 0

async function search(query) {
    const token = ++searchToken
    reader.view?.clearSearch()
    if (!reader.view || !query) return post('searchDone', { query, count: 0 })
    let count = 0
    try {
        for await (const result of reader.view.search({
            query,
            draw: Overlayer.highlight,
            // A tint of the app's honey accent (the light or dark variant
            // for the page's theme), drawn translucent over the text.
            drawOptions: { color: reader.settings?.theme?.dark ? '#ff9f0a' : '#f0861a' },
        })) {
            if (token !== searchToken) return // superseded by a newer search
            if (result === 'done') break
            if (result.subitems) {
                count += result.subitems.length
                post('searchResults', {
                    query,
                    label: result.label?.trim() ?? '',
                    items: result.subitems.map(({ cfi, excerpt }) => ({
                        cfi, pre: excerpt?.pre ?? '', match: excerpt?.match ?? '', post: excerpt?.post ?? '',
                    })),
                })
            } else if (typeof result.progress === 'number') {
                post('searchProgress', { query, progress: result.progress })
            }
        }
    } catch (e) {
        post('log', { level: 'error', message: `search failed: ${e}` })
    }
    if (token === searchToken) post('searchDone', { query, count })
}

function clearSearch() {
    searchToken++
    reader.view?.clearSearch()
}

export { clearSearch, search }
