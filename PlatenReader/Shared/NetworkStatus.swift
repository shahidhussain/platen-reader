import Combine
import Foundation
import Network

/// Whether the device is online, for the home screen's lists: a book kept
/// only in iCloud can be opened (downloaded) while online, and is shown as
/// not available while offline.
///
/// This only listens to the system's own report of the connection
/// (NWPathMonitor); it sends nothing and asks for no permission. Platen
/// itself still never goes on the network.
@MainActor
final class NetworkStatus: ObservableObject {
    static let shared = NetworkStatus()

    @Published private(set) var isOnline = true
    /// Goes up each time the connection changes: online or offline, or one
    /// network for another (Wi-Fi to mobile data, another Wi-Fi). A network
    /// share may come or go with any of these, so the home screen's lists
    /// check their folders and books again.
    @Published private(set) var changes = 0
    private let monitor = NWPathMonitor()
    private var lastPath: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                // The first report is how things are at launch, not a change.
                if let last = self.lastPath, last != path { self.changes += 1 }
                self.lastPath = path
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.platenreader.network-status", qos: .utility))
    }
}
