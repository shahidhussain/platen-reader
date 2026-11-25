import PlatenCore
import SwiftUI
import MessageUI
import UIKit

/// The settings on iOS: a sheet from the gear at the foot of the home
/// screen. They are about how the app works, so they live there, not among
/// the reader's buttons (every one of which is about the book being read).
///
/// Only what the reader's own popovers do not hold is here: one page or
/// scroll and the line width are in the Layout popover; text size, font,
/// line spacing and appearance in Aa. Each setting is in one place only.
/// The Mac's File Types tab has no iOS counterpart. Changes apply to any
/// open book straight away.
struct ReaderSettingsView: View {
    @ObservedObject var settings = ReaderSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var composingFeedback = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    Picker("Page Turn", selection: $settings.pageTurnStyle) {
                        ForEach(PageTurnStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Show Pages Left in Chapter", isOn: $settings.showPagesLeftInChapter)
                    // The explanation is the toggle's second line (the
                    // system's title-and-subtitle row), so it wraps beside
                    // the switch, which sits centred on both lines, instead
                    // of running under it with the title pressed against it
                    // (device testing, 22 Nov 2026).
                    Toggle(isOn: $settings.justify) {
                        Text("Justify Text")
                        Text("Lines flush at both sides, where the book asks for it. Off, lines end where their words do (ragged right), which leaves no wide gaps between words on a narrow screen.")
                    }
                    Toggle(isOn: $settings.hyphenate) {
                        Text("Hyphenate Text")
                        Text("Breaks long words at the ends of lines, so lines are more even and justified text has fewer wide gaps between words. Not used in books whose pages are laid out by the publisher.")
                    }
                }
                ReadAloudSettingsSection()
                OfflineSettingsSection()
                Section {
                    Button("Clear Reading Positions and Bookmarks…", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Platen keeps only where you are in each book and your bookmarks, on this device.")
                }
                Section {
                    // An email to support (ProblemMail): the composer as a
                    // sheet, or with no mail account, a mailto: link.
                    Button("Send Feedback…") {
                        if MFMailComposeViewController.canSendMail() {
                            composingFeedback = true
                        } else if let url = ProblemReport.mailtoURL(subject: ProblemReport.feedbackSubject, body: "") {
                            openURL(url)
                        }
                    }
                    ShareLink(item: DiagnosticsFile(), preview: SharePreview("Platen Reader Diagnostics")) {
                        Text("Share Diagnostics…")
                    }
                } footer: {
                    Text("A record of how the app has been running (how long books took to open, moments it was slow to respond, errors), kept on this device to help with a problem report. It holds no book titles or file names, and leaves the device only if you share it.")
                }
                Section {
                    // About Platen Reader: a page of its own (the shared
                    // AboutView), where the iOS Settings app puts "About".
                    // Acknowledgements are reached from there.
                    NavigationLink {
                        ScrollView {
                            AboutView(icon: Image("AboutIcon"),
                                      copyToClipboard: { UIPasteboard.general.string = $0 })
                                .padding(.horizontal, 20)
                                .padding(.vertical, 24)
                                .frame(maxWidth: .infinity)
                        }
                        .navigationTitle(Text("About"))
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent("About Platen Reader", value: AboutInfo.version)
                    }
                    // Opens the website in the reader's browser; the app
                    // itself loads nothing (spec: no network).
                    Link(destination: AppLinks.website) {
                        LabeledContent("Website") {
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    // A little whimsy, unattributed (Slaughterhouse-Five).
                    Text(verbatim: "Poo-tee-weet?")
                        .font(.system(.footnote, design: .serif).italic())
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear all reading positions and bookmarks?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { try? PositionStore.shared.removeAll() }
            } message: {
                Text("This cannot be undone.")
            }
            .sheet(isPresented: $composingFeedback) {
                FeedbackMailView().ignoresSafeArea()
            }
        }
    }
}

/// Keep Favourites on This Device (OfflineCopies): on unless turned off,
/// with what the copies take up.
private struct OfflineSettingsSection: View {
    @ObservedObject private var offline = OfflineCopies.shared
    @ObservedObject private var favourites = RecentList.favorites

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { offline.isEnabled }, set: { offline.isEnabled = $0 })) {
                Text("Keep Favourites on This Device")
                Text("Favourites in iCloud Drive, on a network share or a drive are copied here, so they can be read offline or away from the share. Removing a book from Favourites deletes its copy.")
            }
        } header: {
            Text("Offline")
        } footer: {
            if offline.isEnabled, !offline.copied.isEmpty {
                let size = ByteCountFormatter.string(fromByteCount: offline.bytes, countStyle: .file)
                Text("Favourites kept on this device: \(offline.copied.count) (\(size)).")
            }
        }
    }
}

/// The mail composer for Send Feedback, addressed to support with the
/// version and system in the subject.
private struct FeedbackMailView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = context.coordinator
        mail.setToRecipients([AppLinks.supportEmail])
        mail.setSubject(ProblemReport.feedbackSubject)
        return mail
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult,
                                               error: Error?) {
            MainActor.assumeIsolated { dismiss() }
        }
    }
}

/// The diagnostics file (`DiagnosticLog`) as the share sheet takes it: a
/// copy made when the reader chooses where to send it, named for the day.
private struct DiagnosticsFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            SentTransferredFile(try DiagnosticLog.shared.export())
        }
    }
}

