import Darwin
import Foundation

/// Notes in the log when the main thread was too busy to answer a tap for a
/// while ("main thread busy for 420 ms"), and where it was busy, so a
/// reader's "it sometimes doesn't respond" can be traced to the code at
/// fault.
///
/// A background timer asks the main thread to answer ten times a second;
/// when an answer comes late by more than `threshold`, the delay is logged.
/// While the main thread is still late, the watch looks at what it is
/// running (at `sampleTimes`): it pauses it for an instant, reads the chain
/// of calls it is in (`MainThreadSampler`), and lets it go on; once the
/// delay is over, those calls are written under the delay's line, named
/// where the app knows their names. A reader's diagnostics file then says
/// not only that Home stuck for a second, but in which function (device
/// testing, 22 Nov 2026: Home stuck on every return to it, with nothing
/// in the log to say why, and Instruments would not attach).
///
/// Cheap (one tiny block on the main queue every tenth of a second, and a
/// look at the main thread only once it is already stuck) and local: it
/// writes to the device's own log and the app's diagnostics file
/// (`DiagnosticLog`), which nothing sends anywhere (spec: no telemetry); the
/// reader can share the file from Settings. The calls are names in the
/// app's and the system's code, never anything about the books.
final class HangWatch: @unchecked Sendable {
    static let shared = HangWatch()

    /// Delays shorter than this pass unremarked: a tap answered within a
    /// quarter of a second feels immediate enough.
    static let threshold: TimeInterval = 0.25

    /// How late the main thread is when it is looked at: three looks at most
    /// per delay, enough to tell one slow call from several in a row.
    static let sampleTimes: [TimeInterval] = [0.3, 0.7, 1.3]

    private let queue = DispatchQueue(label: "org.platenreader.hang-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var waiting = false
    private var asked = Date()
    private var sampler: MainThreadSampler?
    /// The looks taken during the current delay, as lines of calls.
    private var samples: [[String]] = []

    /// Starts watching. Called on the main thread (it is the thread watched).
    func start() {
        let sampler = Thread.isMainThread ? MainThreadSampler() : nil
        queue.async { [self] in
            guard timer == nil else { return }
            self.sampler = sampler
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 0.1, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    private func tick() {
        // Still waiting for the last answer: the main thread is busy. Look
        // at what it is doing, at each of the sample times.
        guard !waiting else {
            let late = Date().timeIntervalSince(asked)
            if samples.count < Self.sampleTimes.count, late >= Self.sampleTimes[samples.count],
               let calls = sampler?.sample() {
                samples.append(calls)
            }
            return
        }
        waiting = true
        asked = Date()
        samples = []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let late = Date().timeIntervalSince(self.asked)
            self.queue.async {
                self.waiting = false
                guard late > Self.threshold else { return }
                log.notice("main thread busy for \(Int(late * 1000), privacy: .public) ms\(Self.describe(self.samples), privacy: .public)")
            }
        }
    }

    /// The looks, one block of lines each, each block only if it differs
    /// from the one before (a single long call shows once).
    static func describe(_ samples: [[String]]) -> String {
        var text = ""
        var previous: [String] = []
        for (index, calls) in samples.enumerated() where !calls.isEmpty {
            if calls == previous {
                text += "\n  look \(index + 1): the same"
                continue
            }
            previous = calls
            text += "\n  look \(index + 1) at \(Int(sampleTimes[index] * 1000)) ms:"
            for call in calls { text += "\n    " + call }
        }
        return text
    }
}

/// Reads the chain of calls the main thread is in, from another thread, the
/// way crash reporters do: the main thread is paused (`thread_suspend`), its
/// registers read, and its stack walked from frame to frame (each frame
/// starts with the one before's address and where to return to), then it
/// goes on. Nothing may allocate memory while it is paused (it may hold the
/// allocator's lock), so the addresses go into space set aside beforehand
/// and are named (`dladdr`) only after it resumes.
///
/// 64-bit ARM only (every iPhone and iPad, and the Simulator on Apple
/// silicon); elsewhere `sample()` gives nothing.
final class MainThreadSampler: @unchecked Sendable {
    /// The most calls kept per look; the top of the chain is what matters.
    static let depth = 40

    private let thread: thread_act_t
    private let addresses: UnsafeMutablePointer<UInt>

    /// Made on the main thread, which it then watches.
    init() {
        thread = mach_thread_self()
        addresses = .allocate(capacity: Self.depth)
    }

    deinit { addresses.deallocate() }

    /// The calls, innermost first: "Platen Reader.debug.dylib  FolderFans.candidates(of:) + 120".
    /// Only the app's own calls and the first few around them are kept,
    /// so a look is a handful of lines.
    func sample() -> [String] {
        let count = capture()
        guard count > 0 else { return [] }
        let all = (0..<count).map { Self.name(addresses[$0]) }
        return Self.trim(all)
    }

    /// Up to `depth` return addresses of the main thread, in `addresses`.
    private func capture() -> Int {
        #if arch(arm64)
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &stateCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var count = 0
        addresses[count] = Self.strip(UInt(state.__pc)); count += 1
        addresses[count] = Self.strip(UInt(state.__lr)); count += 1
        var frame = Self.strip(UInt(state.__fp))
        // Each frame: the caller's frame address, then the return address.
        var pair: (UInt, UInt) = (0, 0)
        while frame != 0, count < Self.depth {
            var read: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &pair) { pointer in
                vm_read_overwrite(mach_task_self_, vm_address_t(frame), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                  vm_address_t(UInt(bitPattern: pointer)), &read)
            }
            guard ok == KERN_SUCCESS else { break }
            let (next, returnAddress) = (Self.strip(pair.0), Self.strip(pair.1))
            if returnAddress == 0 { break }
            addresses[count] = returnAddress; count += 1
            // The stack grows down, so each caller's frame is higher up.
            guard next > frame else { break }
            frame = next
        }
        return count
        #else
        return 0
        #endif
    }

    /// An address without the signature bits system code puts in the top of
    /// saved addresses (pointer authentication).
    private static func strip(_ address: UInt) -> UInt {
        #if targetEnvironment(simulator)
        return address & 0x0000_7FFF_FFFF_FFFF
        #else
        return address & 0x0000_007F_FFFF_FFFF
        #endif
    }

    /// "image  symbol + offset" for an address, or "image + 0x…" where the
    /// symbol's name is not known (stripped release builds), which can be
    /// looked up against that build later.
    private static func name(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return String(format: "?  0x%lx", address)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        if let symbol = info.dli_sname, let start = info.dli_saddr {
            let raw = String(cString: symbol)
            return "\(image)  \(demangle(raw)) + \(address - UInt(bitPattern: start))"
        }
        let base = UInt(bitPattern: info.dli_fbase)
        return String(format: "%@ + 0x%lx", image, address - base)
    }

    /// Swift's own name for a Swift symbol ("FolderFans.candidates(of:)"),
    /// through the runtime's demangler; other names as they are.
    private static func demangle(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return symbol }
        typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                             UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let handle = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return symbol }
        let function = unsafeBitCast(handle, to: Demangle.self)
        return symbol.withCString { name in
            guard let result = function(name, strlen(name), nil, nil, 0) else { return symbol }
            defer { free(result) }
            return String(cString: result)
        }
    }

    /// The calls worth reading: from the innermost down to the fourth of
    /// the app's own (the busy work and what asked for it), not the run loop
    /// and `main` beneath; with none of the app's own, the innermost dozen.
    /// At most 24 lines.
    static func trim(_ calls: [String]) -> [String] {
        var end = min(calls.count, 12)
        var own = 0
        for (index, call) in calls.enumerated() where call.hasPrefix("Platen Reader") {
            own += 1
            end = index + 1
            if own == 4 { break }
        }
        return Array(calls.prefix(min(end, 24)))
    }
}
