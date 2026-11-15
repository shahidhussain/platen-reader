import PlatenCore
import SwiftUI
import UIKit

extension Notification.Name {
    /// Asks the folder view to read its folder again (a reader was closed;
    /// the book may have been moved or deleted meanwhile).
    static let platenFolderShouldRefresh = Notification.Name("platenFolderShouldRefresh")
}

/// The home screen once the reader has chosen a folder: the folder the last
/// book came from, as a grid of large covers (about three across on an
/// iPhone), with the folders inside it first. Tapping a folder goes into it,
/// with the usual Back button; tapping a book opens it.
struct FolderBrowserView: View {
    @ObservedObject var library: LibraryFolder
    let openBook: (URL) -> Void
    let chooseBook: () -> Void
    let chooseFolder: () -> Void

    /// The folders below the chosen one, down to the one on show.
    @State private var path: [URL] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let root = library.root {
                    grid(root)
                }
            }
            .navigationDestination(for: URL.self) { grid($0) }
        }
        .onAppear { path = library.pathFromRoot }
        .onChange(of: path) { _, path in
            guard let root = library.root else { return }
            library.show(path.last ?? root)
        }
        .onChange(of: library.current) { _, _ in
            // A book opened from another folder inside the chosen one: show
            // its folder.
            let wanted = library.pathFromRoot
            if wanted.map(FolderScanner.canonicalPath) != path.map(FolderScanner.canonicalPath) { path = wanted }
        }
    }

    private func grid(_ folder: URL) -> some View {
        FolderGridView(folder: folder, openBook: openBook, chooseBook: chooseBook, chooseFolder: chooseFolder)
            .id(folder) // a new model for each folder
    }
}

/// One folder's grid.
private struct FolderGridView: View {
    let folder: URL
    let openBook: (URL) -> Void
    let chooseBook: () -> Void
    let chooseFolder: () -> Void
    @StateObject private var model: FolderModel

    init(folder: URL, openBook: @escaping (URL) -> Void, chooseBook: @escaping () -> Void, chooseFolder: @escaping () -> Void) {
        self.folder = folder
        self.openBook = openBook
        self.chooseBook = chooseBook
        self.chooseFolder = chooseFolder
        _model = StateObject(wrappedValue: FolderModel(folder: folder))
    }

    /// At least 100 points wide: three across on every iPhone in portrait
    /// (even the smallest), more on iPad and in landscape.
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 18, alignment: .bottom)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(model.entries) { entry in
                    Button {
                        tapped(entry)
                    } label: {
                        switch entry.kind {
                        case .folder:
                            FolderTile(name: entry.name)
                        case .book:
                            BookTile(entry: entry, info: model.covers[entry.url], image: model.images[entry.url],
                                     isDownloading: model.downloading.contains(entry.url))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .overlay {
            if !model.hasLoaded {
                // Reading the folder (slow for a large one or a network
                // share): not empty, just not read yet.
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for books…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if model.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Books Here", systemImage: "books.vertical")
                } description: {
                    Text("Books added to this folder in Files appear here.")
                }
            }
        }
        .overlay(alignment: .bottom) {
            let (done, total) = model.coverProgress
            if model.hasLoaded, total > 0, done < total {
                CoverProgress(done: done, total: total)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.coverProgress.done < model.coverProgress.total)
        .navigationTitle(folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: chooseBook) { Label("Open Book…", systemImage: "book") }
                    Button(action: chooseFolder) { Label("Choose Folder…", systemImage: "folder") }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .refreshable { model.refresh() }
        .onAppear {
            model.onDownloaded = openBook
            model.start()
        }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .platenFolderShouldRefresh)) { _ in
            model.refresh()
        }
    }

    private func tapped(_ entry: FolderEntry) {
        switch entry.kind {
        case .folder:
            // Pushed through the stack's path (navigationDestination).
            LibraryFolder.shared.show(entry.url)
        case .book where entry.isDownloaded:
            openBook(entry.url)
        case .book:
            // In iCloud only: fetch it first; it opens when it arrives.
            model.download(entry)
        }
    }
}

/// While covers are being made: a small bar floating at the bottom, with
/// how many are done. Covers are made once and kept, so this shows the
/// first time a folder is opened (or after many books are added).
private struct CoverProgress: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: Double(done), total: Double(total))
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text("Making covers: \(done) of \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tiles

/// A book: its cover, bottom-aligned in a 2:3 space so covers of different
/// shapes sit on one line, with the title below.
private struct BookTile: View {
    let entry: FolderEntry
    let info: BookCoverInfo?
    let image: CGImage?
    let isDownloading: Bool

    private var title: String { info?.title ?? entry.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .bottom) { cover }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var cover: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        } else {
            PlainCover(title: title, author: info?.authors.first)
                .overlay(alignment: .bottomTrailing) {
                    if !entry.isDownloaded {
                        Group {
                            if isDownloading {
                                ProgressView()
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.body.weight(.medium))
                            }
                        }
                        .padding(8)
                        .foregroundStyle(.white)
                    }
                }
        }
    }

    private var accessibilityLabel: String {
        var parts = [title]
        if let author = info?.authors.first { parts.append(author) }
        if !entry.isDownloaded {
            parts.append(isDownloading ? String(localized: "Downloading") : String(localized: "In iCloud"))
        }
        return parts.joined(separator: ", ")
    }
}

/// A cover for a book without a picture (or one not downloaded yet): the
/// title and author on a quiet colour chosen from the title, so the same
/// book always looks the same.
private struct PlainCover: View {
    let title: String
    let author: String?

    private static let colours: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.52), Color(red: 0.50, green: 0.36, blue: 0.33),
        Color(red: 0.33, green: 0.46, blue: 0.40), Color(red: 0.45, green: 0.40, blue: 0.53),
        Color(red: 0.55, green: 0.47, blue: 0.32), Color(red: 0.30, green: 0.43, blue: 0.47),
    ]

    private var colour: Color {
        // A stable choice (String.hashValue changes every launch).
        let sum = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.colours[sum % Self.colours.count]
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(colour.gradient)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.7)
                    if let author {
                        Text(author)
                            .font(.system(.caption2, design: .serif))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(.white)
                .padding(10)
            }
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }
}

/// A folder inside the one on show.
private struct FolderTile: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                }
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Folder: \(name)"))
        .accessibilityAddTraits(.isButton)
    }
}
