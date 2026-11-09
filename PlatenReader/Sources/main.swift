import AppKit

// Entry point. There is no nib or storyboard: the menu bar is built in code
// (MainMenu.swift) and windows are created by BookDocument.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
