import SwiftUI

/// Shown in place of the page when a book cannot be opened.
struct OpenFailureView: View {
    let title: String
    let detail: String?

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
