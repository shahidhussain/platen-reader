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
    /// Sends each time the connection really changes: online or offline,
    /// or one network for another (Wi-Fi to mobile data, another Wi-Fi). A
    /// network share may come or go with any of these, so the home screen's
    /// lists check their folders and books again.
    ///
    /// Not every report from the system: iOS sends one whenever anything
    /// about the connection shifts (its quality, its addresses, whether it
    /// is expensive), which on a phone can be every few seconds, and each
    /// had every list check every remote folder and book again, and
    /// redrawn, keeping the app busy (a laggy app, device testing, 26 Nov
    /// 2026). A subject rather than a published value, so views that only
    /// show whether the device is online are not redrawn for it.
    let changed = PassthroughSubject<Void, Never>()
    private let monitor = NWPathMonitor()
    /// What a change is judged by: online or not, and which networks.
    private var last: (online: Bool, networks: [String])?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // The networks in use, by name (en0, pdp_ip0…) and kind.
            let networks = path.availableInterfaces.map { "\($0.name):\($0.type)" }.sorted()
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                // The first report is how things are at launch, not a change.
                if let last = self.last, last.online != online || last.networks != networks {
                    log.info("network: \(online ? "online" : "offline", privacy: .public), \(networks.count) networks")
                    self.changed.send()
                }
                self.last = (online, networks)
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.platenreader.network-status", qos: .utility))
    }
}
