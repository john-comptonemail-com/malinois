//
//  WatchLinkWakes.swift
//  MalinoisWatch
//
//  The background wakes watchOS gives the watch app to deliver its iPhone's queued alerts (ADR 0043),
//  each held until the alerts it brought are handled (item 57), and given back by a deadline of the
//  app's own at the latest (item 212): watchOS ends an app whose wake for the link outlasts 15 seconds
//  of wall time, and on 1.8.2 (79) it did so with a wake still held, before the expiration handler
//  gave it back. Foundation-only, so the iPhone test suite compiles it too and fires the deadline itself.
//

import Foundation

/// The wakes held for the iPhone link, each given back to watchOS once: when the watch app's rule says
/// nothing is left to deliver, when watchOS says the wake's time is up, or at `deadline`, whichever
/// comes first. A wake given back at its deadline may leave an alert unposted: watchOS may then suspend
/// the app, and the alert is shown when the app next runs, or lost if watchOS ends the app first. Where
/// the handling would have outlasted watchOS's 15 seconds, ending the app would lose it too; where it
/// would have ended between the deadline and the 15 seconds, the deadline is what cuts it off (item
/// 218's Codex-2, which corrects "would lose too" for that case). So the inbox gives the alerts of one
/// run one allowance for the notification list (`WatchRelayInbox`), and a backlog does not reach the
/// deadline waiting for the list. Keeping each alert until it is shown is BACKLOG item 219.
@MainActor
final class WatchLinkWakes<Wake: AnyObject> {
    /// How long a wake is held at most (item 212). watchOS allows a link wake 15 seconds of wall time
    /// ("WatchConnectivity watchdog transgression. Exhausted wall time allowance of 15.00 seconds."),
    /// counted from before the app hears of the wake, so this leaves five for that and the giving back.
    nonisolated static var deadline: TimeInterval { 10 }

    private var held: [(token: Int, wake: Wake)] = []
    private var lastToken = 0
    private let end: @MainActor (Wake) -> Void
    private let after: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    /// `end` gives a wake back to watchOS; `after` runs an action once a delay has passed (in the watch
    /// app a sleeping task on the main actor; in the tests, the test's own hand).
    init(end: @escaping @MainActor (Wake) -> Void,
         after: @escaping @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void) {
        self.end = end
        self.after = after
    }

    /// How many wakes are held now.
    var count: Int { held.count }

    /// Holds `wake` until something gives it back, and gives it back at `deadline` if nothing has by
    /// then. The deadline names the wake by a token of its own, so it never reaches a later one.
    func hold(_ wake: Wake) {
        lastToken += 1
        let token = lastToken
        held.append((token, wake))
        after(Self.deadline) { [weak self] in self?.giveBack(token: token) }
    }

    /// Gives back every wake held: nothing is left to deliver.
    func giveBackAll() {
        let all = held
        held.removeAll()
        all.forEach { end($0.wake) }
    }

    /// Gives back one wake, once: its expiration handler, its deadline and `giveBackAll` can all reach it.
    func giveBack(_ wake: Wake) {
        guard let index = held.firstIndex(where: { $0.wake === wake }) else { return }
        end(held.remove(at: index).wake)
    }

    /// A wake's deadline: gives it back if it is still held.
    private func giveBack(token: Int) {
        guard let index = held.firstIndex(where: { $0.token == token }) else { return }
        end(held.remove(at: index).wake)
    }
}
