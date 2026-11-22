import Foundation
import os

/// The reader's log, shared by the Mac and iOS apps. Read it in Console, or
/// with `log stream --predicate 'subsystem == "Platen Reader"'` (on the Mac)
/// or `xcrun simctl spawn booted log stream --predicate …` (Simulator).
///
/// Each line also goes to the app's own diagnostics file (`DiagnosticLog`,
/// iOS only), which the reader can share from Settings when reporting a
/// problem. Debug lines go only to the device's log.
let log = PlatenLog()

/// How a value in a log line is treated, as `OSLogPrivacy` does for the
/// device's log, with one more case for the diagnostics file.
enum LogPrivacy {
    /// Shown everywhere.
    case `public`
    /// Hidden everywhere ("<private>").
    case `private`
    /// A book's or a folder's name, or a search: shown in the device's log
    /// (where the debug scripts read them), but left out of the diagnostics
    /// file, which a reader may send to someone else and which should not
    /// carry their reading list.
    case name
}

/// How a number in a log line is written.
enum LogFormat {
    /// With this many decimal places.
    case fixed(precision: Int)
}

/// A log line written with string interpolation, as for `Logger`
/// ("Read \(name, privacy: .name) in \(ms, format: .fixed(precision: 0)) ms"),
/// worked out once into the two forms it is kept in.
struct LogMessage: ExpressibleByStringInterpolation {
    /// For the device's log: private values hidden.
    var system: String
    /// For the diagnostics file: names hidden as well.
    var file: String

    init(stringLiteral value: String) {
        system = value
        file = value
    }

    init(stringInterpolation: Interpolation) {
        system = stringInterpolation.system
        file = stringInterpolation.file
    }

    struct Interpolation: StringInterpolationProtocol {
        var system = ""
        var file = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            system.reserveCapacity(literalCapacity + interpolationCount * 8)
            file.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        mutating func appendLiteral(_ literal: String) {
            system += literal
            file += literal
        }

        /// Numbers and true/false are public unless said otherwise, as in
        /// `Logger`; anything else (text above all) is private.
        mutating func appendInterpolation(_ value: some BinaryInteger, privacy: LogPrivacy = .public) {
            append(String(value), privacy)
        }

        mutating func appendInterpolation(_ value: Double, format: LogFormat? = nil, privacy: LogPrivacy = .public) {
            switch format {
            case .fixed(let precision): append(String(format: "%.\(precision)f", value), privacy)
            case nil: append(String(value), privacy)
            }
        }

        mutating func appendInterpolation(_ value: CGFloat, format: LogFormat? = nil, privacy: LogPrivacy = .public) {
            appendInterpolation(Double(value), format: format, privacy: privacy)
        }

        mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .public) {
            append(value ? "true" : "false", privacy)
        }

        mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .private) {
            append(String(describing: value), privacy)
        }

        private mutating func append(_ text: String, _ privacy: LogPrivacy) {
            switch privacy {
            case .public:
                system += text
                // An error's description may quote a file's name (“Moby
                // Dick.epub” couldn't be opened): quoted names are left out.
                file += Self.withoutQuotedNames(text)
            case .private:
                system += "<private>"
                file += "<private>"
            case .name:
                system += text
                file += "<name>"
            }
        }

        /// Text with anything in curly double quotes (as system errors quote
        /// names) replaced by “…”.
        static func withoutQuotedNames(_ text: String) -> String {
            guard text.contains("\u{201C}") else { return text }
            var result = ""
            var quoted = false
            for character in text {
                if character == "\u{201C}" {
                    quoted = true
                    result += "\u{201C}…"
                } else if character == "\u{201D}", quoted {
                    quoted = false
                    result.append(character)
                } else if !quoted {
                    result.append(character)
                }
            }
            return result
        }
    }
}

/// Writes to the device's log (as `Logger`) and to the diagnostics file.
struct PlatenLog: Sendable {
    private let logger = Logger(subsystem: "Platen Reader", category: "reader")

    func debug(_ message: LogMessage) {
        logger.debug("\(message.system, privacy: .public)")
    }

    func info(_ message: LogMessage) {
        logger.info("\(message.system, privacy: .public)")
        DiagnosticLog.shared.add(message.file, level: "")
    }

    func notice(_ message: LogMessage) {
        logger.notice("\(message.system, privacy: .public)")
        DiagnosticLog.shared.add(message.file, level: "")
    }

    func warning(_ message: LogMessage) {
        logger.warning("\(message.system, privacy: .public)")
        DiagnosticLog.shared.add(message.file, level: "warning: ")
    }

    func error(_ message: LogMessage) {
        logger.error("\(message.system, privacy: .public)")
        DiagnosticLog.shared.add(message.file, level: "error: ")
    }

    func fault(_ message: LogMessage) {
        logger.fault("\(message.system, privacy: .public)")
        DiagnosticLog.shared.add(message.file, level: "fault: ")
    }
}
