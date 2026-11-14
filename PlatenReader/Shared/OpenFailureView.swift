import SwiftUI

/// Shown in place of the page when a book cannot be opened.
struct OpenFailureView: View {
    let title: String
    let detail: String?

    init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    /// The message for an error from opening a book or PDF. Platen's own
    /// errors say what went wrong and what to do; for any other, `fallback`
    /// is the title and the system's description the detail.
    init(error: Error, fallback: String) {
        if let error = error as? LocalizedError {
            self.init(title: error.errorDescription ?? fallback, detail: error.recoverySuggestion)
        } else {
            self.init(title: fallback, detail: error.localizedDescription)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(40)
        #if os(macOS)
        .frame(width: 460)
        #else
        .frame(maxWidth: 460) // phones are narrower than 460 points
        #endif
        .textSelection(.enabled)
    }
}
