import AppKit

/// The menu bar, built in code. The menu bar carries the full command set,
/// which is what lets the on-page overlay stay sparse (spec: "Mac
/// conventions first"). Actions are sent to the first responder, so they
/// reach the active reader window's `ReaderViewController`.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = represented
        return item
    }

    private static func arrow(_ code: Int) -> String {
        String(Character(UnicodeScalar(UInt16(code))!))
    }

    private static func appMenu() -> NSMenu {
        let name = String(localized: "Platen Reader")
        let menu = NSMenu(title: name)
        menu.addItem(item(String(localized: "About \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        menu.addItem(.separator())
        let settings = item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(settings)
        menu.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: String(localized: "Services"))
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(item(String(localized: "Open…"), #selector(NSDocumentController.openDocument(_:)), "o"))

        // Open Recent: AppKit fills this in once it recognises the menu.
        let recent = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: String(localized: "Open Recent"))
        recentMenu.addItem(item(String(localized: "Clear Menu"), #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = recentMenu
        // Long-standing (if undocumented) way to tell AppKit this is the
        // recent-documents menu when there is no nib.
        recentMenu.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        menu.addItem(recent)

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Copy with Citation"), #selector(ReaderViewController.copyWithCitation(_:)), "c", [.command, .shift]))
        menu.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Share Selection…"), #selector(ReaderViewController.shareSelection(_:))))
        menu.addItem(.separator())
        let find = NSMenuItem(title: String(localized: "Find"), action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: find.title)
        findMenu.addItem(item(String(localized: "Find in Book…"), #selector(ReaderViewController.findInBook(_:)), "f"))
        findMenu.addItem(item(String(localized: "Find Next"), #selector(ReaderViewController.findNext(_:)), "g"))
        findMenu.addItem(item(String(localized: "Find Previous"), #selector(ReaderViewController.findPrevious(_:)), "g", [.command, .shift]))
        findMenu.addItem(item(String(localized: "Search Book for Selection"), #selector(ReaderViewController.searchForSelection(_:)), "e"))
        find.submenu = findMenu
        menu.addItem(find)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(item(String(localized: "Paginated"), #selector(ReaderViewController.showPaginated(_:)), "1"))
        menu.addItem(item(String(localized: "Scroll"), #selector(ReaderViewController.showScroll(_:)), "2"))
        menu.addItem(.separator())

        let layout = NSMenuItem(title: String(localized: "Page Layout"), action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: layout.title)
        for option in PageLayout.allCases {
            layoutMenu.addItem(item(option.label, #selector(ReaderViewController.setPageLayout(_:)), represented: option.rawValue))
        }
        layout.submenu = layoutMenu
        menu.addItem(layout)

        let theme = NSMenuItem(title: String(localized: "Appearance"), action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: theme.title)
        for option in AppearanceChoice.allCases {
            themeMenu.addItem(item(option.label, #selector(ReaderViewController.setThemeFromMenu(_:)), represented: option.rawValue))
        }
        theme.submenu = themeMenu
        menu.addItem(theme)
        menu.addItem(.separator())

        menu.addItem(item(String(localized: "Larger Text"), #selector(ReaderViewController.makeTextBigger(_:)), "+"))
        // ⌘= as an unlisted alternative, since + needs Shift on most layouts.
        let equals = item(String(localized: "Larger Text"), #selector(ReaderViewController.makeTextBigger(_:)), "=")
        equals.isAlternate = false
        equals.isHidden = true
        equals.allowsKeyEquivalentWhenHidden = true
        menu.addItem(equals)
        menu.addItem(item(String(localized: "Smaller Text"), #selector(ReaderViewController.makeTextSmaller(_:)), "-"))
        menu.addItem(item(String(localized: "Default Text Size"), #selector(ReaderViewController.makeTextDefaultSize(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Show Contents"), #selector(ReaderViewController.toggleContents(_:)), "t"))
        // Also the C key on its own (handled by the reader, so it never
        // interferes with typing in the search field).
        menu.addItem(item(String(localized: "Show Controls"), #selector(ReaderViewController.toggleReaderControls(_:)), "k"))
        menu.addItem(.separator())
        // AppKit recognises this action and keeps the title in sync.
        menu.addItem(item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Go"))
        menu.addItem(item(String(localized: "Previous Page"), #selector(ReaderViewController.previousPageLeft(_:)),
                          arrow(NSLeftArrowFunctionKey), []))
        menu.addItem(item(String(localized: "Next Page"), #selector(ReaderViewController.nextPageRight(_:)),
                          arrow(NSRightArrowFunctionKey), []))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Previous Chapter"), #selector(ReaderViewController.previousChapter(_:)),
                          arrow(NSLeftArrowFunctionKey)))
        menu.addItem(item(String(localized: "Next Chapter"), #selector(ReaderViewController.nextChapter(_:)),
                          arrow(NSRightArrowFunctionKey)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Back"), #selector(ReaderViewController.goBackInHistory(_:)), "["))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Bookmark This Page"), #selector(ReaderViewController.toggleBookmark(_:)), "d"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(item(String(localized: "Minimise"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Help"))
        menu.addItem(item(String(localized: "Show Reading Controls"), #selector(ReaderViewController.showReadingControls(_:))))
        return menu
    }
}
