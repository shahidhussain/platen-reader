import SwiftUI

/// Shown in place of the page when a book cannot be opened: what went wrong
/// and what to do, then (spec, "Failure handling") a link to the guide for a
/// DRM-protected book, or for anything else "Report This Book…", which
/// writes an email to support with a diagnostics file attached (the reader
/// sees it before it goes; attaching the book itself is a choice, off by
/// default).
struct OpenFailureView: View {
    let title: String
    let detail: String?
    /// Links to the DRM guide (a DRM-protected book).
    var drmGuide = false
    /// Writes the report; told whether to attach the book. Nil: no button.
    var report: ((_ attachBook: Bool) -> Void)?

    @State private var attachBook = false

    init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    /// The message for an error from opening a book or PDF. Platen's own
    /// errors say what went wrong and what to do; for any other, `fallback`
    /// is the title and the system's description the detail. `report`
    /// writes the report (DRM books get the guide instead).
    init(error: Error, fallback: String, report: ((_ attachBook: Bool) -> Void)? = nil) {
        if let error = error as? LocalizedError {
            self.init(title: error.errorDescription ?? fallback, detail: error.recoverySuggestion)
        } else {
            self.init(title: fallback, detail: error.localizedDescription)
        }
        if ErrorCode.isDRM(error) {
            drmGuide = true
        } else {
            self.report = report
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
            if drmGuide {
                Link(destination: AppLinks.drmGuide) {
                    Text("About DRM-Protected Books")
                }
                .padding(.top, 8)
            }
            if let report {
                VStack(spacing: 8) {
                    Button {
                        report(attachBook)
                    } label: {
                        Text("Report This Book…")
                    }
                    #if os(macOS)
                    .controlSize(.large)
                    #else
                    .buttonStyle(.bordered)
                    #endif
                    Toggle(isOn: $attachBook) {
                        Text("Attach the book to the email")
                    }
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #else
                    .toggleStyle(.switch)
                    .fixedSize()
                    #endif
                    .font(.callout)
                    Text("Your mail app shows the email before it is sent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)
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
