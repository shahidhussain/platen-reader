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
        guard bookSentToShell, !state.sidebarVisible, presentedViewController == nil else { return [escape] }

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

    @objc private func keyLeft() { js("platen.goLeft()") }
    @objc private func keyRight() { js("platen.goRight()") }
    @objc private func keyNext() { js("platen.next()") }
    @objc private func keyPrevious() { js("platen.prev()") }
    @objc private func keyPreviousChapter() { js("platen.prevSection()") }
    @objc private func keyNextChapter() { js("platen.nextSection()") }
    @objc private func keyBack() { js("platen.goBack()") }
    @objc private func keyBookmark() { js("platen.toggleBookmark()") }
    @objc private func keyContents() { showSidebar(tab: .contents) }
    @objc private func keyFind() {
        showSidebar(tab: .search)
        state.searchFocusRequest += 1
    }
    @objc private func keyFindNext() { stepThroughHits(by: 1) }
    @objc private func keyFindPrevious() { stepThroughHits(by: -1) }
    @objc private func keyBigger() { settings.biggerText() }
    @objc private func keySmaller() { settings.smallerText() }
    @objc private func keyDefaultSize() { settings.defaultTextSize() }
    @objc private func keyControls() { setOverlay(visible: !overlayVisible) }
    @objc private func keyLayoutOne() { setLayout(.onePage) }
    @objc private func keyLayoutTwo() { setLayout(.twoPages) }
    @objc private func keyLayoutScroll() { setLayout(.scroll) }

    /// Esc closes the panel, then the controls.
    @objc private func escapePressed() {
        if presentedViewController != nil, !state.sidebarVisible {
            dismiss(animated: true)
        } else if state.sidebarVisible {
            state.sidebarVisible = false
        } else if overlayVisible {
            setOverlay(visible: false)
        }
    }

    /// The contents popover hangs from the overlay's button, so the overlay
    /// is shown first.
    private func showSidebar(tab: ReaderState.SidebarTab) {
        state.sidebarTab = tab
        let wasHidden = !overlayVisible
        setOverlay(visible: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasHidden ? 0.2 : 0)) { [weak self] in
            self?.state.sidebarVisible = true
        }
    }

    /// Find Next / Previous: step through the search results.
    private func stepThroughHits(by step: Int) {
        let hits = state.allHits
        guard !hits.isEmpty else { return keyFind() }
        let current = hits.firstIndex { $0.id == state.currentHitID }
        let next = current.map { ($0 + step + hits.count) % hits.count } ?? (step > 0 ? 0 : hits.count - 1)
        goToHit(hits[next])
    }
}
