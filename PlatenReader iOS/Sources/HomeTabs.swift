import PlatenCore
import SwiftUI
import UIKit

/// The home screen.
///
/// The first time Platen is opened, with nothing to show (no folders, no
/// recent books, no favourites), it is the welcome alone: Open Book… and
/// Choose Folder…. As soon as a book is opened or a folder chosen, the
/// welcome is gone for good and the home screen is three tabs:
/// - **Home:** the reader's folders (the ones they chose), as a list (a
///   folder opens inside the tab), and the first few favourites, in the
///   order the reader puts them (HomeSections.swift). Settings is the gear.
/// - **Favourites:** books the reader marked as favourites (a cover's
///   long-press menu), "what I am reading now".
/// - **Recent Books:** books opened lately, from anywhere, newest first.
struct HomeTabs: View {
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions
    @ObservedObject private var books = RecentList.books
    @ObservedObject private var folders = RecentList.folders
    @ObservedObject private var favourites = RecentList.favorites

    private var isFirstRun: Bool { books.items.isEmpty && folders.items.isEmpty && favourites.items.isEmpty }

    var body: some View {
        Group {
            if isFirstRun {
                WelcomeView(open: actions.chooseBook, chooseFolder: actions.chooseFolder)
            } else {
                HomeTabRow(navigation: navigation, actions: actions)
            }
        }
        // The first book opened from the welcome: closing it comes back to
        // Recent Books, where it is, rather than to an empty Home.
        .onChange(of: isFirstRun) { _, first in
            if !first, folders.items.isEmpty { navigation.tab = .books }
        }
    }
}

/// The three tabs side by side, which slide sideways under the finger (or
/// when a tab is tapped), so they read as three pages in a row. The tab bar
/// stays at the bottom even inside a folder, so the reader can always get
/// back out; there, a swipe right goes back instead (the row stands still).
///
/// The system's tab view cannot slide between its tabs, so the sections are
/// pages of a paging scroll view, with a tab bar of Platen's own on glass.
struct HomeTabRow: View {
    @ObservedObject var navigation: HomeNavigation
    let actions: HomeActions
    /// The page the row is scrolled to (follows the finger).
    @State private var shown: HomeNavigation.Tab? = .home

    /// Inside a folder the row stands still: a swipe goes back.
    private var rowLocked: Bool { navigation.tab == .home && !navigation.folderPath.isEmpty }

    var body: some View {
        // The row spans the whole width, safe areas included, and each page
        // is inset by the side safe areas within its own full-width slot. Paging moves by
        // the row's full width, so a page only the safe width wide left the
        // next tab showing in the strip beside it: where the status bar runs
        // down one side (an iPhone Duo opened out, 22 Nov 2026), or the
        // notch's strips on an iPhone turned sideways.
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            // The row's bottom safe area takes in the tab bar, and the
            // keyboard when it is up (the tab bar rides up on it), but the
            // pages' navigation stacks hand neither on to what is in them,
            // which gets only the device's own. So a folder's last row of
            // covers stayed under the tab bar, and its search results ran on
            // under the keyboard, out of reach (reported 26 Nov 2026). Each
            // page is told the row's (`tabRowBottom`), and its scroll view
            // makes room for what it was not given (`roomBelow`).
            ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(HomeNavigation.Tab.allCases, id: \.self) { tab in
                        page(tab)
                            // Padding, not safe-area padding: each tab's own
                            // navigation bar must move in too.
                            .padding(.leading, insets.leading)
                            .padding(.trailing, insets.trailing)
                            .environment(\.tabRowBottom, insets.bottom)
                            // The strips beside it in the page's own colour.
                            .background(slotColour(tab), ignoresSafeAreaEdges: .all)
                            .containerRelativeFrame(.horizontal)
                            .id(tab)
                    }
                }
                .scrollTargetLayout()
            }
            .ignoresSafeArea(.container, edges: .horizontal)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $shown)
            .scrollIndicators(.hidden)
            .scrollDisabled(rowLocked)
            // A new width (an iPhone Duo folded or opened, a turn) leaves the
            // row at its old offset, part-way into another page: back to the
            // tab chosen.
            .onChange(of: outer.size) { _, _ in
                let tab = navigation.tab
                DispatchQueue.main.async { reader.scrollTo(tab, anchor: .leading) }
            }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HomeTabBar(selection: Binding(get: { navigation.tab }, set: { tab in
                // Tapping Home again goes back to the list of folders.
                if tab == navigation.tab, tab == .home { navigation.folderPath = [] }
                navigation.tab = tab
            }))
        }
        // A swipe that settles on a page makes it the tab; a tab chosen
        // (tapped, or a folder just chosen) slides the row to it.
        .onChange(of: shown) { _, tab in
            if let tab, tab != navigation.tab { navigation.tab = tab }
        }
        .onChange(of: navigation.tab) { _, tab in
            guard shown != tab else { return }
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy(duration: 0.35)) { shown = tab }
        }
        // A tab chosen before the row was laid out (a folder chosen at
        // launch, or from the welcome): go to it once it is on screen.
        .onAppear {
            DispatchQueue.main.async { if shown != navigation.tab { shown = navigation.tab } }
        }
    }

    /// The colour behind a page, carried into the side strips: Home's list
    /// of folders is grouped (grey in light mode); a folder's grid and the
    /// shelves are plain.
    private func slotColour(_ tab: HomeNavigation.Tab) -> Color {
        tab == .home && navigation.folderPath.isEmpty ? Color(.systemGroupedBackground) : Color(.systemBackground)
    }

    @ViewBuilder private func page(_ tab: HomeNavigation.Tab) -> some View {
        switch tab {
        case .home: RecentFoldersView(navigation: navigation, actions: actions)
        case .books: BookShelfView(shelf: .recent, actions: actions)
        case .favourites: BookShelfView(shelf: .favourites, actions: actions)
        }
    }
}

/// The tab bar: Home, Recent Books and Favourites, on glass, the one shown
/// picked out.
struct HomeTabBar: View {
    @Binding var selection: HomeNavigation.Tab

    var body: some View {
        HStack(spacing: 4) {
            item(.home, "Home", "house")
            item(.favourites, "Favourites", "heart")
            item(.books, "Recent Books", "clock")
        }
        .padding(4)
        .overlaySurface(Capsule())
        .padding(.bottom, 4)
    }

    private func item(_ tab: HomeNavigation.Tab, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        let selected = selection == tab
        return Button { selection = tab } label: {
            VStack(spacing: 2) {
                Image(systemName: selected ? symbol + ".fill" : symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: 100, height: 48)
            .background {
                if selected { Capsule().fill(Color.primary.opacity(0.08)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
