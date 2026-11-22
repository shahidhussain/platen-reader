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
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { if self?.isOnline != online { self?.isOnline = online } }
        }
        monitor.start(queue: DispatchQueue(label: "org.platenreader.network-status", qos: .utility))
    }
}
