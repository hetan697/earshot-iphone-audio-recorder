import Foundation
import Network

@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    @Published private(set) var onWiFi = SyncPolicy.onWiFi
    @Published private(set) var isConnected = SyncPolicy.networkAvailable
    @Published private(set) var pathResolved = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "earshot.connectivity")

    var maySyncNow: Bool {
        guard pathResolved else { return false }
        switch SyncPolicy.mode {
        case .always: return isConnected
        case .never: return false
        case .wifiOnly: return isConnected && onWiFi
        }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let wifi = connected && path.usesInterfaceType(.wifi)
            Task { @MainActor in
                SyncPolicy.networkAvailable = connected
                SyncPolicy.onWiFi = wifi
                self?.isConnected = connected
                self?.onWiFi = wifi
                self?.pathResolved = true
                if connected { Export.copyPending() }
            }
        }
        monitor.start(queue: queue)
    }
}
