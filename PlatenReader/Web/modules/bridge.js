// Platen Reader: Messages to Swift (post) and forwarding of script errors.


// ---------------------------------------------------------------------------
// Bridge to Swift

// The message's data travels under its own key, so no field of it can
// clash with the message type.
const post = (type, body = {}) => {
    try {
        window.webkit.messageHandlers.platen.postMessage({ type, body })
    } catch {
        // Running in a plain browser for debugging: log instead.
        console.log('[platen →]', type, body)
    }
}

// Forward uncaught errors so they show up in Xcode's console.
window.addEventListener('error', e => post('log', { level: 'error', message: `${e.message} (${e.filename}:${e.lineno})` }))
window.addEventListener('unhandledrejection', e => post('log', { level: 'error', message: String(e.reason?.stack ?? e.reason) }))

export { post }
