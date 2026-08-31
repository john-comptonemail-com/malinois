//
//  ConnectivityMonitor.swift
//  Malinois
//
//  Wraps NWPathMonitor to report network reachability. Two jobs:
//    • auto-flush pending evidence the instant a usable path returns, and
//    • detect the *total* loss of connectivity that — for a stationary armed
//      device which had a working path at arm — is a strong indicator of jamming.
//
//  Note: iOS exposes no cellular signal strength to apps, so this observes the
//  symptom (no usable network path), never the cause. The engine adds the
//  discriminators (had-a-path-at-arm, stationary, debounced) that make a total
//  loss meaningful rather than noise.
//

import Foundation
import Network

@MainActor
final class ConnectivityMonitor: ObservableObject {

    /// True while any usable network path exists.
    @Published private(set) var isOnline = true

    /// Fired on every online↔offline transition (true == a usable path exists).
    var onChange: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.malinois.connectivity", qos: .utility)
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                self.onChange?(online)
            }
        }
        monitor.start(queue: queue)
    }
}
