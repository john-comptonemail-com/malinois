//
//  MonitoringEngine+PushAssertion.swift
//  Malinois
//
//  Item 153's MAL-01 (1.8.1; ADR 0003 amended). The engine spawned its fact pushes on bare tasks, so the lapse record
//  written as the scene left the foreground, and a trip's fact pushed just before a lock or a kill, had no
//  background-task assertion until the uploader took one after its identity lookup and its queue wait. Now the spawn
//  holds one from before the task exists (the status records' spawn, `logStateChange`, does the same in the main
//  file), and the uploader's own assertion covers the push itself from its lookup on. Moved here from
//  MonitoringEngine.swift, which sits at the lint limit.
//

import Foundation

extension MonitoringEngine {
    /// Pushes the bare fact of an event to iCloud at once (Pro only, iCloud backup permitting), on a task that holds
    /// a background-task assertion from before it is spawned: a lock or a kill right now finds it held (item 153's
    /// MAL-01). The uploader takes its own from the lookup on; UIKit allows both.
    func pushFactIfCloud(_ event: Event) {
        guard cloudAllowed, backupAllows(event) else { return }   // item 115
        let hold = BackgroundAssertion.begin("malinois-fact-task")
        Task {
            defer { hold.end() }
            await cloud.pushFact(event)   // enqueue awaits the chained work, so this returns post-attempt
            handleEncryptedDataResetIfNeeded()   // R3-2: fact pushes consume the reset flag too
        }
    }
}
