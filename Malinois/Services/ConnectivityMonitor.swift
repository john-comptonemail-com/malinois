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

    /// The snapshot-safe reading (R1-L2): connectivity that has actually been OBSERVED.
    /// `isOnline` deliberately defaults optimistic for live behavior, but an arm-time
    /// snapshot taken before NWPath's first report (the crash-recovery re-arm at launch is
    /// the realistic window) must read offline — otherwise an offline arm records "had a
    /// path", and a later offline trigger force-sirens in Stealth on a false jamming call.
    var observedOnline: Bool { hasFirstReport && isOnline }

    /// Whether NWPath has reported at least once — set before the change-only guard below,
    /// because the first report is informative even when it matches the optimistic default.
    private(set) var hasFirstReport = false

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
                guard let self else { return }
                self.hasFirstReport = true
                guard self.isOnline != online else { return }
                self.isOnline = online
                self.onChange?(online)
            }
        }
        monitor.start(queue: queue)
    }
}
