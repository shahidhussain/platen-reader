import PlatenCore
import SwiftUI

/// Get Info for a book in the folder view (a long press on its cover): its
/// title and author if known, the file's full name, kind and size, where it
/// is (as Files would say it, and the full path), and when it was created,
/// last modified and last accessed, and last opened in Platen (from Recent
/// Books, which is exact, where iOS's access date is not).
///
/// The file's details are asked for in the background, with a time limit,
/// as a file on a network share that has gone away can keep the question
/// waiting; what the folder listing already knows shows meanwhile.
struct BookInfoView: View {
    let entry: FolderEntry
    /// The title and authors, if the book has been read (not for a book
    /// only in iCloud).
    let info: BookCoverInfo?
    @Environment(\.dismiss) private var dismiss
    @State private var details: FileDetails?
    @State private var waiting = true

    var body: some View {
        NavigationStack {
            Form {
                if let title = info?.title {
                    Section {
                        LabeledContent("Title", value: title)
                        if let authors = info?.authors, !authors.isEmpty {
                            LabeledContent(authors.count == 1 ? "Author" : "Authors",
                                           value: authors.formatted(.list(type: .and)))
                        }
                    }
                }
                Section {
                    row("File Name", entry.url.lastPathComponent)
                    LabeledContent("Kind", value: BookFileType(entry.url)?.label ?? "—")
                    LabeledContent("Size", value: (details?.size ?? entry.size).map {
                        $0.formatted(.byteCount(style: .file))
                    } ?? "—")
                    if !entry.isDownloaded {
                        LabeledContent("Stored", value: String(localized: "In iCloud, not on this device"))
                    }
                }
                Section {
                    row("Where", StoragePlace(path: entry.url.path).location)
                    row("Path", entry.url.path, monospaced: true)
                }
                Section {
                    date("Created", details?.created ?? entry.created)
                    date("Modified", details?.modified ?? entry.modified)
                    date("Last Accessed", details?.accessed)
                    if let opened = RecentList.books.item(at: entry.url)?.lastOpened {
                        date("Last Opened in Platen", opened)
                    }
                } footer: {
                    if waiting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Asking the file system…")
                        }
                    } else {
                        #if os(iOS)
                        Text("iOS updates a file’s last-accessed date only now and then, so it can be well behind.")
                        #else
                        Text("macOS updates a file’s last-accessed date only now and then, so it can be well behind.")
                        #endif
                    }
                }
            }
            .navigationTitle(info?.title ?? entry.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .formStyle(.grouped)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .task {
            details = await FileDetails.read(entry.url, timeout: 5)
            waiting = false
        }
    }

    /// A label above its value, for long values (names, paths) that would
    /// be squeezed beside it; the value can be selected and copied.
    private func row(_ label: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .footnote.monospaced() : .body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func date(_ label: LocalizedStringKey, _ date: Date?) -> some View {
        LabeledContent(label, value: date?.formatted(date: .abbreviated, time: .shortened) ?? "—")
    }
}

/// What the file system says about a file: its size and dates. `accessed`
/// is the file's access date, which iOS keeps only roughly (it may not
/// change on every read).
struct FileDetails: Sendable {
    var size: Int64?
    var created: Date?
    var modified: Date?
    var accessed: Date?

    /// Reads them on a queue of its own, giving up (nil) after `timeout`
    /// seconds.
    static func read(_ url: URL, timeout: TimeInterval) async -> FileDetails? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce<FileDetails?>(continuation)
            queue.async {
                let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey,
                                                 .contentAccessDateKey]
                let values = try? url.resourceValues(forKeys: keys)
                once.resume(values.map {
                    FileDetails(size: $0.fileSize.map(Int64.init), created: $0.creationDate,
                                modified: $0.contentModificationDate, accessed: $0.contentAccessDate)
                })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    private static let queue = DispatchQueue(label: "org.platenreader.file-details", qos: .userInitiated)
}
