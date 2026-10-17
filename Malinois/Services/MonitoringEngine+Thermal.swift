//
//  MonitoringEngine+Thermal.swift
//  Malinois
//
//  The thermal sentinel (item 38), moved out of MonitoringEngine.swift, which sits at the lint
//  size limits, to make room for 1.7's items; unchanged apart from the visibility an extension
//  needs. Its per-watch state stays on the class.
//

import Foundation

extension MonitoringEngine {
    // Heat alone can make iOS shut the phone down, with no tripwire touched: the one power-off
    // an attacker can cause from across the room. While a watch is live, iOS's thermal state
    // reaching "serious", and then "critical", each leaves one audit record, so the log shows
    // the heat before the silence and, on Pro, the cloud copy lands while the phone still runs.
    // Never a siren or a cross-device alert (ADR 0001: ambient heat looks like induced heat),
    // which is why these ride the silent audit type, like `gaLifted`.

    /// Pure (unit-tested; item 38): the record, if any, that a thermal state reached during a
    /// live watch earns. One at the first `.serious` and one at the first `.critical`, so a
    /// phone that flaps between fair and serious writes nothing more, and cooling from
    /// critical to serious is not a new record.
    nonisolated static func thermalRecordKind(for thermalState: ProcessInfo.ThermalState,
                                              alreadyLogged: Set<String>) -> String? {
        switch thermalState {
        case .serious:
            return alreadyLogged.isDisjoint(with: ["thermalSerious", "thermalCritical"]) ? "thermalSerious" : nil
        case .critical:
            return alreadyLogged.contains("thermalCritical") ? nil : "thermalCritical"
        default:
            return nil
        }
    }

    /// Pure (unit-tested): how a record spells iOS's thermal state (item 38, choice 3); nil for a
    /// state a later iOS adds.
    nonisolated static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return nil
        }
    }

    /// iOS reported a new thermal state (item 38). Recorded only while a watch is live.
    func handleThermalStateChange(_ thermalState: ProcessInfo.ThermalState) {
        guard armedSince != nil,
              let kind = Self.thermalRecordKind(for: thermalState, alreadyLogged: thermalKindsLogged) else { return }
        thermalKindsLogged.insert(kind)
        logStateChange(kind)
    }

    /// Starts listening at go-live, and records a phone already hot at that moment.
    func startThermalSentinel() {
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.handleThermalStateChange(self.thermalState())
                }
        }
        handleThermalStateChange(thermalState())
    }

    /// Stops listening at the disarm; the next watch records afresh.
    func stopThermalSentinel() {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        thermalKindsLogged.removeAll()
    }
}
