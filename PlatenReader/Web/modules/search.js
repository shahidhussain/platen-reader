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
            drawOptions: { color: '#ffcc00' },
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
