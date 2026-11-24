import Foundation

/// The app's own record of how it has been running, kept in a small file on
/// the device so a reader reporting a problem ("it sometimes sticks") can
/// send it from Settings (Share Diagnostics…), with no cable, Mac or
/// Terminal needed (asked for in device testing, 22 Nov 2026).
///
/// Every log line at info level and above goes here as well as to the
/// device's log (`PlatenLog`): how long books took to open, any moment the
/// app was too busy to answer a tap (`HangWatch`), errors. Book titles,
/// file names and searches are left out ("<name>"), so the file says
/// nothing about what is being read. Each launch starts with a line naming
/// the app's version, the system and the kind of device.
///
/// Nothing is sent anywhere (spec: no telemetry, no network): the file stays
/// on the device unless the reader shares it. It is kept to about half a
/// megabyte (`limit`), the oldest lines dropped first, and lives in
/// Application Support, so it outlasts a crash or a force-quit (the
/// device's own log keeps little and is hard to reach).
///
/// Only the iOS app turns it on (`start`); elsewhere lines are dropped.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog(directory: DiagnosticLog.defaultDirectory)

    /// The most the file may hold; past it, the older half is dropped.
    static let limit = 512 * 1024

    static var defaultDirectory: URL {
        #if DEBUG
        // Automated runs keep theirs apart from the reader's own.
        if let home = ProcessInfo.processInfo.environment["PLATEN_TEST_HOME"] {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("diagnostics", isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Platen Reader", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    let fileURL: URL

    // Everything below is touched only on `queue`, so writing never holds up
    // the main thread.
    private let queue = DispatchQueue(label: "org.platenreader.diagnostics", qos: .utility)
    private var enabled = false
    private var pending: [String] = []
    private var flushScheduled = false
    /// The last line's text, and how many times since it came again: a line
    /// repeated straight after itself (a page turn reports its place several
    /// times) is kept once, followed by a count.
    private var lastText = ""
    private var repeats = 0
    private let timestamps: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("Diagnostics.txt")
    }

    /// Starts keeping lines, beginning with one that says which app, system
    /// and device this launch is.
    func start() {
        let about = Self.aboutThisDevice
        queue.async { [self] in
            enabled = true
            pending.append("")
            append("Launched: \(about)", date: Date())
            scheduleFlush()
        }
    }

    /// Adds a line (`text`, after `level`, such as "error: "). Written out
    /// within a second, in batches.
    func add(_ text: String, level: String) {
        let date = Date()
        queue.async { [self] in
            guard enabled else { return }
            append(level + text, date: date)
            scheduleFlush()
        }
    }

    /// Writes out what is waiting now (for the tests, and before sharing).
    func flush() {
        queue.sync { writePending() }
    }

    /// A copy of the file to share: a temporary file named for the moment
    /// it was made (`fileName`), which
    /// begins by saying what it is and which device it is from.
    func export(now: Date = Date()) throws -> URL {
        try queue.sync {
            writePending()
            let saved = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let header = """
            Platen Reader diagnostics, made \(timestamps.string(from: now))
            \(Self.aboutThisDevice)
            Book titles, file names and searches are left out (shown as <name>).

            """
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(Self.fileName(at: now))
            try (header + saved).write(to: copy, atomically: true, encoding: .utf8)
            return copy
        }
    }

    /// The shared copy's name, with the date and time it was made, in the
    /// style of the Mac's screenshots ("Platen Reader Diagnostics 2026-11-22
    /// at 10.41.14.txt"; a file name may not hold a colon), so two shared on
    /// the same day do not collide (the second was renamed on the Mac, to a
    /// name that read like a year: device testing, 22 Nov 2026).
    static func fileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Platen Reader Diagnostics \(formatter.string(from: date)).txt"
    }

    /// For the tests: turned on without the launch line.
    func enableForTesting() {
        queue.sync { enabled = true }
    }

    // MARK: - On the queue

    private func append(_ text: String, date: Date) {
        if text == lastText {
            repeats += 1
            return
        }
        noteRepeats()
        lastText = text
        // One line per entry: a multi-line message (a script error and its
        // stack) is indented under its first line.
        let body = text.replacingOccurrences(of: "\n", with: "\n    ")
        pending.append("\(timestamps.string(from: date)) \(body)")
    }

    private func noteRepeats() {
        if repeats > 0 { pending.append("    (and \(repeats) more the same)") }
        repeats = 0
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [self] in writePending() }
    }

    private func writePending() {
        flushScheduled = false
        noteRepeats()
        lastText = ""
        guard !pending.isEmpty else { return }
        let data = Data((pending.joined(separator: "\n") + "\n").utf8)
        pending.removeAll()
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.write(contentsOf: data)
        try? handle.close()
        if Int(size) + data.count > Self.limit { trim() }
    }

    /// Drops the older half of the file, cutting at the start of a line.
    private func trim() {
        guard let data = try? Data(contentsOf: fileURL), data.count > Self.limit / 2 else { return }
        var kept = data.suffix(Self.limit / 2)
        if let newline = kept.firstIndex(of: UInt8(ascii: "\n")) {
            kept = kept[kept.index(after: newline)...]
        }
        try? Data(kept).write(to: fileURL, options: .atomic)
    }

    // MARK: - About this device

    /// "Platen Reader 0.8.28 (3f2a9c1), iOS 26.1 (23B85), iPhone17,1": the
    /// app's version, the system and the kind of device (its model code,
    /// never the name the owner gave it).
    static var aboutThisDevice: String {
        let info = Bundle.main.infoDictionary ?? [:]
        var app = "Platen Reader \(info["CFBundleShortVersionString"] as? String ?? "?")"
        if let commit = info["PlatenCommit"] as? String, !commit.isEmpty { app += " (\(commit))" }
        #if os(iOS)
        let system = "iOS"
        #else
        let system = "macOS"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return "\(app), \(system) \(osVersion), \(modelCode)"
    }

    /// The kind of device: its model code ("iPhone17,2", "Mac15,6"), never
    /// the name its owner gave it.
    static var modelCode: String {
        // In the Simulator the model is the Mac's; it says which device is simulated.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated + " (Simulator)"
        }
        #if os(macOS)
        // The Mac's model code ("Mac15,3"); uname says only "arm64".
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &model, &size, nil, 0) == 0 { return String(cString: model) }
        }
        #endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
