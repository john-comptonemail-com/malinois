//
//  BackgroundAssertion.swift
//  Malinois
//
//  Item 153's MAL-01 (1.8.1; ADR 0003 amended). The extra running time iOS grants an app whose scene has left the
//  foreground is asked for with a background-task assertion. Every cloud push used to ask for it only once its
//  identity lookup and its queue wait were over, and the engine spawned its push tasks without one, so the lapse
//  record written as the phone was locked, and a trip's fact pushed just before a lock or a kill, ran unprotected
//  through their first step (milliseconds with a warm CloudKit cache, up to the lookup's 10 s deadline cold). Now an
//  assertion covers a push from its first step: begun before the lookup, or before the task that will run it, and
//  ended on every return.
//

import UIKit

/// One background-task assertion: begun before a push's first step, ended when the push ends, on every path. UIKit
/// allows several at once, so a push begun under the engine's assertion may hold its own.
@MainActor
final class BackgroundAssertion {
    /// What `begin` and `end` call: UIKit's, or a test's recorder.
    @MainActor
    struct Provider {
        var begin: @MainActor (_ name: String, _ expired: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
        var end: @MainActor (_ id: UIBackgroundTaskIdentifier) -> Void

        static let uiKit = Provider(
            begin: { name, expired in UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expired) },
            end: { UIApplication.shared.endBackgroundTask($0) })
    }

    private var id: UIBackgroundTaskIdentifier = .invalid
    private let provider: Provider

    private init(provider: Provider) { self.provider = provider }

    /// Begins an assertion now, under `name` (UIKit's label for it).
    static func begin(_ name: String) -> BackgroundAssertion {
        let assertion = BackgroundAssertion(provider: current)
        assertion.start(name)
        return assertion
    }

    private func start(_ name: String) {
        id = provider.begin(name) { [weak self] in
            // Time expired before the work finished. The event keeps its pending state and is retried on the next
            // sync; log it so the drop is visible.
            Log.cloud.error("Background time expired mid-upload; event stays pending and will retry")
            self?.end()
        }
    }

    /// Ends the assertion once; later calls do nothing (`defer` and the expiry handler may both call it).
    func end() {
        guard id != .invalid else { return }
        provider.end(id)
        id = .invalid
    }

    private static var current: Provider {
        #if DEBUG
        if let providerForTesting { return providerForTesting }
        #endif
        return .uiKit
    }

    #if DEBUG
    /// Replaces UIKit for the tests (item 153's MAL-01): a recorder sees each begin and end in order against the
    /// identity lookup it also observes. Nil restores UIKit.
    static var providerForTesting: Provider?
    #endif
}
