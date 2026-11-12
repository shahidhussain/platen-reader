import os

/// The reader's log, shared by the Mac and iOS apps. Read it in Console, or
/// with `log stream --predicate 'subsystem == "Platen Reader"'` (on the Mac)
/// or `xcrun simctl spawn booted log stream --predicate …` (Simulator).
let log = Logger(subsystem: "Platen Reader", category: "reader")
