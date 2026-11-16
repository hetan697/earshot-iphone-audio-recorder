import Foundation
import Network

@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    @Published private(set) var onWiFi = SyncPolicy.onWiFi
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "earshot.connectivity")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor in
                SyncPolicy.onWiFi = wifi
                self?.onWiFi = wifi
                if wifi { Export.copyPending() }
            }
        }
        monitor.start(queue: queue)
    }
}
