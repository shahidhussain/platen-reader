import UIKit

// Hardware keyboards on iPad and iPhone (spec, "iOS and iPadOS": the Mac
// shortcuts apply, listed in the iPad ⌘ shortcut overlay). Each command has a
// title, which is what the ⌘ overlay shows; the arrows and space have none
// there (as in Apple's own apps) but still work.
extension ReaderViewController {
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        // While a popover or sheet is up (search field, settings), keys
        // belong to it: only Esc is ours.
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        guard session.isOpenInPage, !state.sidebarVisible, presentedViewController == nil else { return [escape] }

        func command(_ title: String, _ input: String, _ flags: UIKeyModifierFlags = .command,
                     _ action: Selector, discoverable: Bool = true) -> UIKeyCommand {
            let c = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
            c.wantsPriorityOverSystemBehavior = true // before the web view scrolls
            if !discoverable { c.attributes = .hidden }
            return c
        }
        var commands = [
            command(String(localized: "Previous Page"), UIKeyCommand.inputLeftArrow, [], #selector(keyLeft), discoverable: false),
            command(String(localized: "Next Page"), UIKeyCommand.inputRightArrow, [], #selector(keyRight), discoverable: false),
            command(String(localized: "Next Page"), " ", [], #selector(keyNext), discoverable: false),
            command(String(localized: "Previous Page"), " ", .shift, #selector(keyPrevious), discoverable: false),
            command(String(localized: "Previous Chapter"), UIKeyCommand.inputLeftArrow, .command, #selector(keyPreviousChapter)),
            command(String(localized: "Next Chapter"), UIKeyCommand.inputRightArrow, .command, #selector(keyNextChapter)),
            command(String(localized: "Back"), "[", .command, #selector(keyBack)),
            command(String(localized: "Bookmark This Page"), "d", .command, #selector(keyBookmark)),
            command(String(localized: "Show Contents"), "t", .command, #selector(keyContents)),
            command(String(localized: "Find in Book…"), "f", .command, #selector(keyFind)),
            command(String(localized: "Find Next"), "g", .command, #selector(keyFindNext)),
            command(String(localized: "Find Previous"), "g", [.command, .shift], #selector(keyFindPrevious)),
            command(String(localized: "Larger Text"), "+", .command, #selector(keyBigger)),
            command(String(localized: "Larger Text"), "=", .command, #selector(keyBigger), discoverable: false),
            command(String(localized: "Smaller Text"), "-", .command, #selector(keySmaller)),
            command(String(localized: "Default Text Size"), "0", .command, #selector(keyDefaultSize)),
            command(String(localized: "Show Controls"), "c", [], #selector(keyControls)),
            command(ReadingLayout.onePage.label, "1", .command, #selector(keyLayoutOne)),
            command(ReadingLayout.scroll.label, "3", .command, #selector(keyLayoutScroll)),
            escape,
        ]
        if state.allowsTwoPages {
            commands.append(command(ReadingLayout.twoPages.label, "2", .command, #selector(keyLayoutTwo)))
        }
        return commands
    }

    @objc private func keyLeft() { session.turn(.left) }
    @objc private func keyRight() { session.turn(.right) }
    @objc private func keyNext() { session.turn(.next) }
    @objc private func keyPrevious() { session.turn(.prev) }
    @objc private func keyPreviousChapter() { session.previousChapter() }
    @objc private func keyNextChapter() { session.nextChapter() }
    @objc private func keyBack() { session.goBack() }
    @objc private func keyBookmark() { session.toggleBookmark() }
    @objc private func keyContents() { showSidebar(tab: .contents) }
    @objc private func keyFind() {
        showSidebar(tab: .search)
        state.searchFocusRequest += 1
    }
    @objc private func keyFindNext() { if !session.stepThroughHits(by: 1) { keyFind() } }
    @objc private func keyFindPrevious() { if !session.stepThroughHits(by: -1) { keyFind() } }
    @objc private func keyBigger() { settings.biggerText() }
    @objc private func keySmaller() { settings.smallerText() }
    @objc private func keyDefaultSize() { settings.defaultTextSize() }
    @objc private func keyControls() { chrome.toggle() }
    @objc private func keyLayoutOne() { session.setLayout(.onePage) }
    @objc private func keyLayoutTwo() { session.setLayout(.twoPages) }
    @objc private func keyLayoutScroll() { session.setLayout(.scroll) }

    /// Esc closes the panel, then the controls.
    @objc private func escapePressed() {
        if state.noteOpen {
            session.closeNote()
        } else if presentedViewController != nil, !state.sidebarVisible {
            dismiss(animated: true)
        } else if state.sidebarVisible {
            state.sidebarVisible = false
        } else if chrome.isVisible {
            chrome.setVisible(false)
        }
    }

    /// The contents popover hangs from the overlay's button, so the overlay
    /// is shown first.
    func showSidebar(tab: ReaderState.SidebarTab) {
        state.sidebarTab = tab
        let wasHidden = !chrome.isVisible
        chrome.setVisible(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasHidden ? 0.2 : 0)) { [weak self] in
            self?.state.sidebarVisible = true
        }
    }
}
