import CryptoKit
import Foundation
import PlatenCore

/// Where the natural voice is downloaded from (docs/read-aloud.md, "Hosting
/// the voice"): a release of Platen's own GitHub repository, pinned here by
/// size and SHA-256, so a file that is not exactly this one is refused,
/// wherever it came from. A new voice pack is a new release and a new pin.
enum KokoroVoiceRelease {
    static let url = URL(string: "https://github.com/shahidhussain/platen-reader/releases/download/voice-1/kokoro-pack.zip")!
    static let sha256 = "2caa08283147f186bd42c1782ff4da1958463d628b36657dccd0d0f0e89188f6"
    static let size: Int64 = 81_807_738
    /// What it takes once unpacked.
    static let unpackedSize: Int64 = 103_067_208
}

/// Why the voice could not be downloaded, in words for the reader.
enum KokoroVoiceDownloadError: LocalizedError {
    case notEnoughSpace(needed: Int64)
    case damaged
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed):
            let size = Measurement(value: Double(needed) / 1_000_000, unit: UnitInformationStorage.megabytes)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided))
            return String(localized: "There is not enough free space. The better voice needs about \(size).")
        case .damaged:
            return String(localized: "The download was incomplete or damaged. Please try again.")
        case .failed(let reason):
            return reason
        }
    }
}

/// Downloads the natural voice, checks it and installs it
/// (`KokoroPack.downloadFolder`). The one network request read aloud makes,
/// and only when the reader has agreed to it (spec: the second network
/// exception). The request carries nothing about the reader: no cookies, no
/// cache, and a user agent of just "PlatenReader".
final class KokoroVoiceDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloaded: URL?
    private var progress: (@MainActor (Double) -> Void)?

    /// Downloads, checks and installs the voice; returns its folder.
    /// Cancelling the task cancels the download.
    func download(progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try Self.checkSpace()
        self.progress = progress
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["User-Agent": "PlatenReader"]
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: KokoroVoiceRelease.url)
        let file: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let started = Date()
        let folder = try await Task.detached(priority: .userInitiated) { try Self.install(from: file) }.value
        log.info("natural voice: downloaded and installed (checking and unpacking took \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        return folder
    }

    // MARK: - Checking and installing

    /// The space the download and the unpacked voice need at once, with
    /// some to spare.
    static var spaceNeeded: Int64 { KokoroVoiceRelease.size + KokoroVoiceRelease.unpackedSize + 50_000_000 }

    private static func checkSpace() throws {
        let folder = KokoroPack.downloadFolder.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < spaceNeeded {
            throw KokoroVoiceDownloadError.notEnoughSpace(needed: spaceNeeded)
        }
    }

    /// Checks the file against the pin, unpacks it beside the voice folder
    /// and then puts it in the folder's place, so a voice is either all there
    /// or not there at all.
    static func install(from file: URL) throws -> URL {
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == KokoroVoiceRelease.size, try sha256(of: file) == KokoroVoiceRelease.sha256 else {
            throw KokoroVoiceDownloadError.damaged
        }
        let destination = KokoroPack.downloadFolder
        let staging = destination.deletingLastPathComponent().appendingPathComponent("Voice (incoming)", isDirectory: true)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let archive = try ZipArchive(source: try FileByteSource(url: file))
            for entry in archive.entries where !entry.isDirectory {
                // Only plain paths inside the folder (nothing like "../x").
                let parts = entry.path.split(separator: "/")
                guard !parts.isEmpty, !entry.path.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." }) else {
                    throw KokoroVoiceDownloadError.damaged
                }
                let target = staging.appendingPathComponent(entry.path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try archive.data(for: entry).write(to: target)
            }
            guard KokoroPack.isComplete(staging) else { throw KokoroVoiceDownloadError.damaged }
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: staging, to: destination)
            // It can always be downloaded again: not in the device's backups.
            var folder = destination
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            return destination
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : KokoroVoiceRelease.size
        let fraction = min(1, Double(totalBytesWritten) / Double(total))
        if let progress { Task { @MainActor in progress(fraction) } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns: kept somewhere of ours.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-pack-\(UUID().uuidString).zip")
        if (downloadTask.response as? HTTPURLResponse)?.statusCode == 200, (try? FileManager.default.moveItem(at: location, to: kept)) != nil {
            lock.withLock { downloaded = kept }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, file) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URL?) in
            defer { self.continuation = nil }
            return (self.continuation, downloaded)
        }
        if let error {
            if (error as? URLError)?.code == .cancelled { continuation?.resume(throwing: CancellationError()) }
            else { continuation?.resume(throwing: KokoroVoiceDownloadError.failed(error.localizedDescription)) }
        } else if let file {
            continuation?.resume(returning: file)
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            log.error("natural voice: download answered \(status, privacy: .public)")
            continuation?.resume(throwing: KokoroVoiceDownloadError.damaged)
        }
    }
}
