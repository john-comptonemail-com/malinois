//
//  EvidenceBundleItem.swift
//  Malinois
//
//  The export bundle as an item of the share sheet (BACKLOG item 90, phase 4; ADR 0067). The sheet opens at once, as
//  before; the bundle is made only when the owner picks where to send it, so a share cancelled spends no signature,
//  and removed once the sheet is gone. Only the sheet's operation for the destination picked makes it: iOS asks the
//  sheet's items as soon as it opens, before anything is picked, and those asks get only a bundle already made (the
//  device check of 2026-10-31). A bundle that cannot be made is left out, and the sentence and the media go as before.
//  Item 223's diagnostic (D7 (a), in 1.13's TestFlight build): each ask for the ZIP and each share's end is written to
//  the share log, with its thread and its time; log lines only, naming no record.
//

import SwiftUI
import Synchronization
import UIKit

final class EvidenceBundleItem: UIActivityItemProvider, @unchecked Sendable {
    private enum State {
        case waiting
        case made(URL?)
        case finished
    }

    /// What a task waited for made, and whether the waiter has given up on it (item 220's defect 1): a bundle that arrives
    /// after the limit is removed at once, by whichever of the two comes second. Not private: the order no test of the
    /// item can stage, a making that ends just as the limit runs out, is tested on it alone.
    final class Made: Sendable {
        private let state = Mutex<(url: URL?, givenUp: Bool)>((nil, false))

        /// The making's result: kept for the waiter, or removed when the waiter has given up.
        func arrive(_ url: URL?) {
            let late = state.withLock { state -> Bool in
                guard !state.givenUp else { return true }
                state.url = url
                return false
            }
            if late { Self.remove(url) }
        }

        /// The waiter gives up: a result already here is removed now, one still to come when it arrives.
        func giveUp() {
            let here = state.withLock { state -> URL? in
                state.givenUp = true
                defer { state.url = nil }
                return state.url
            }
            Self.remove(here)
        }

        /// The result, for a waiter the making did not keep past its limit.
        var url: URL? { state.withLock { $0.url } }

        /// A bundle's ZIP is in a folder of its own: that folder goes.
        private static func remove(_ url: URL?) {
            if let url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
    }

    private let make: @Sendable () async -> URL?
    private let state = Mutex<State>(.waiting)
    /// Whether the making for a destination that takes files gave a ZIP (item 200): nil until it ran. Apart from `state`,
    /// whose lock a making holds, so a read never waits on one; kept once the share is over.
    private let outcome = Mutex<Bool?>(nil)
    /// Where item 223's diagnostic lines go (D7 (a)): the share log, in the open, unless a test gives another.
    private let report: @Sendable (String) -> Void
    /// When the item was made, just before its sheet opens: the diagnostic's times are counted from here.
    private let opened = ContinuousClock.now
    /// Whether a making is under way (item 223's diagnostic): apart from `state`, whose lock a making holds, so the
    /// sheet's ask can say so before it waits for that lock.
    private let making = Mutex(false)
    /// How many shares this launch has made: the last one's number.
    private static let shares = Mutex(0)

    /// This share's number in this launch (item 223's diagnostic), so one share's lines can be told from another's.
    let share: Int

    /// How long a share waits for its bundle, in seconds (item 220's defect 1). The making signs the export statement
    /// through App Attest, whose calls have no deadline of their own, and can ask Apple to certify a new key; it also
    /// waits its turn behind a signing pass under way, then copies and zips the record's photos and clips. A minute
    /// leaves room for those, and a call that never answers no longer holds the share, and the app's screen with it,
    /// for good. A share whose making is slower than this goes without the bundle and can be made again.
    static let makingLimit: TimeInterval = 60

    /// How long this item's making may take: `makingLimit`, unless a test gives another.
    let limit: TimeInterval

    /// - Parameters:
    ///   - placeholder: where the bundle's ZIP will be, by name: the sheet reads only its kind, a file.
    ///   - limit: how long the making may take before the share goes on without the bundle.
    ///   - report: where item 223's diagnostic lines go: the share log, in the open, unless a test gives another.
    ///   - make: makes the bundle and returns its ZIP, in a folder of its own; nil when it cannot.
    init(placeholder: URL, limit: TimeInterval = EvidenceBundleItem.makingLimit,
         report: @escaping @Sendable (String) -> Void = { EvidenceBundleItem.log($0) },
         make: @escaping @Sendable () async -> URL?) {
        self.make = make
        self.limit = limit
        self.report = report
        share = Self.shares.withLock { shares in
            shares += 1
            return shares
        }
        super.init(placeholderItem: placeholder)
    }

    /// The bundle Share offers for `record`, with `log` as the app holds it: one only for a record this phone signed,
    /// once the signer has compared the log on disk in this launch (item 182, codex-3 on 68bd96b3), and while a key can
    /// sign its export statement (item 187, deepseek-1); nil without an exporter (a test's screen).
    static func forShare(of record: Event, log: [Event], exporter: EvidenceExporter?) async -> EvidenceBundleItem? {
        await offer(of: record, log: log, exporter: exporter).item
    }

    /// What Share offers for `record`: its bundle, on the terms `forShare` states, and when there is none the signer's
    /// reason, for the event's screen to say after the share (item 200); no reason without an exporter (a test's screen).
    static func offer(of record: Event, log: [Event], exporter: EvidenceExporter?) async -> ShareOffer {
        guard let exporter else { return ShareOffer(item: nil, readiness: nil) }
        let readiness = await exporter.signer.exportReadiness(record.id)
        guard readiness == .ready else { return ShareOffer(item: nil, readiness: readiness) }
        let placeholder = exporter.temporaryDirectory.appendingPathComponent(EvidenceExporter.bundleName(for: record) + ".zip")
        return ShareOffer(item: EvidenceBundleItem(placeholder: placeholder) { try? await exporter.bundle(of: record, log: log) },
                          readiness: readiness)
    }

    /// Whether the bundle was made for the destination picked (item 200): nil while no destination that takes files has
    /// asked for it (none picked, a share cancelled, or one that takes no file); false when its making gave none, so the
    /// share went without it; true when it was made. Kept once the share is over; never waits on a making.
    var madeForTheDestination: Bool? { outcome.withLock { $0 } }

    /// Whether the bundle is being made now (item 223's diagnostic); never waits on a making.
    var makingUnderWay: Bool { making.withLock { $0 } }

    /// The sheet's end (item 223's diagnostic): reports how the share ended and whether the ZIP's making was asked for.
    func shareEnded(destination: UIActivity.ActivityType?, completed: Bool) {
        report(ShareDiagnostic.end(share: share, after: ContinuousClock.now - opened, completed: completed,
                                   destination: destination, made: madeForTheDestination))
    }

    /// Writes one of item 223's diagnostic lines to the share log, in the open: it names no record.
    static func log(_ line: String) {
        Log.share.notice("\(line, privacy: .public)")
    }

    /// Called on a secondary thread once the owner picks where to send the share, the destination in `activityType`: the
    /// only place the bundle is made. It may not be nil: a bundle not made has its placeholder here, and the sheet's ask
    /// below leaves it out. Each ask is reported, with its thread, its time and what it got (item 223's diagnostic).
    override var item: Any {
        let asked = ContinuousClock.now
        let onMain = Thread.isMainThread
        let destination = activityType
        let bundle = madeBundle(for: destination)
        report(ShareDiagnostic.operationAsk(share: share, onMain: onMain, after: asked - opened, destination: destination,
                                            took: ContinuousClock.now - asked, got: bundle != nil))
        if let bundle { return bundle }
        return placeholderItem ?? NSNull()
    }

    /// The sheet's own ask for the item, on the main thread: the bundle its operation made for the destination picked, or
    /// nil to leave it out. It never makes one: iOS asks as soon as the sheet opens, before any destination is picked,
    /// and a bundle made then spent a signature on a sheet that might be cancelled, the main thread held meanwhile. Each
    /// ask is reported, with its thread, its time, whether a making was under way and how long the ask waited (item
    /// 223's diagnostic: whether this ask ever waits on a making).
    override func activityViewController(_ activityViewController: UIActivityViewController,
                                         itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        let asked = ContinuousClock.now
        let onMain = Thread.isMainThread
        let whileMaking = makingUnderWay
        let bundle = keptBundle(for: activityType)
        report(ShareDiagnostic.sheetAsk(share: share, onMain: onMain, after: asked - opened, destination: activityType,
                                        whileMaking: whileMaking, waited: ContinuousClock.now - asked, got: bundle != nil))
        return bundle
    }

    /// The system's destinations that take photos, videos, text or links but never a ZIP: Save Image or Save Video,
    /// Print, Assign to Contact, Add to Reading List, Books and Markup; and Copy, as a ZIP on the clipboard is of little
    /// use. iOS asks every item once any destination is picked; for these the bundle is left out, so none is made and no
    /// signature is spent. A destination iOS does not name, another app's or Save to Files, may take a file, and gets it.
    static let destinationsWithoutFiles: Set<UIActivity.ActivityType> = [
        .saveToCameraRoll, .print, .assignToContact, .addToReadingList, .openInIBooks, .markupAsPDF, .copyToPasteboard,
    ]

    /// The bundle for `destination`: none for one that takes no file; otherwise as `madeBundle()`.
    func madeBundle(for destination: UIActivity.ActivityType?) -> URL? {
        Self.takesFile(destination) ? madeBundle() : nil
    }

    /// The bundle already made, for `destination`: none for one that takes no file, none before it is made, none once
    /// the share is over. Never makes one; an ask while it is being made waits for it.
    private func keptBundle(for destination: UIActivity.ActivityType?) -> URL? {
        guard Self.takesFile(destination) else { return nil }
        return state.withLock { state in
            if case .made(let url) = state { return url }
            return nil
        }
    }

    /// Whether `destination` may take a file: one iOS does not name may.
    static func takesFile(_ destination: UIActivity.ActivityType?) -> Bool {
        guard let destination else { return true }
        return !destinationsWithoutFiles.contains(destination)
    }

    /// The bundle's ZIP, made the first time it is asked for and kept; nil when it could not be made, when its making
    /// took longer than the item's limit (item 220's defect 1: the share then goes without it, as when it cannot be
    /// made, and the event's screen says so), or when the share is over. Whoever asks while it is being made waits for
    /// it, for that limit at most, so it is made once.
    func madeBundle() -> URL? {
        state.withLock { state -> URL? in
            switch state {
            case .made(let url):
                return url
            case .finished:
                return nil
            case .waiting:
                making.withLock { $0 = true }
                let url = Self.wait(for: make, atMost: limit)
                making.withLock { $0 = false }
                state = .made(url)
                outcome.withLock { $0 = url != nil }
                return url
            }
        }
    }

    /// Once the sheet is gone: removes the bundle's folder (after a bundle being made is done) and makes none after.
    func finish() {
        state.withLock { state in
            if case .made(let url?) = state { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            state = .finished
        }
    }

    /// Runs `make` on a thread that may wait, the sheet's own, off the main thread, and waits for it `limit` seconds at
    /// most (item 220's defect 1: the wait had no limit, so a making that never ended held that thread for good). At that
    /// thread's priority, so the sheet never waits on work of a lower one. Past the limit there is no bundle for this
    /// share: the making is left to end by itself, and what it then gives is removed at once.
    private static func wait(for make: @escaping @Sendable () async -> URL?, atMost limit: TimeInterval) -> URL? {
        let done = DispatchSemaphore(value: 0)
        let made = Made()
        Task.detached(priority: Task.currentPriority) {
            made.arrive(await make())
            done.signal()
        }
        guard done.wait(timeout: .now() + limit) == .success else {
            made.giveUp()
            return nil
        }
        return made.url
    }
}

/// What Share offers for a record: its bundle, if any, and why there is none (item 200); nil readiness without an exporter.
struct ShareOffer {
    let item: EvidenceBundleItem?
    let readiness: EvidenceExportReadiness?
}

/// The line the event's screen shows after a share that went without the signed evidence ZIP (item 200; the owner,
/// 2026-11-07: "as you recommend, wording approved"), until the owner leaves the screen.
enum ShareNote {
    static let noCertifiedKey = "Sent without the signed evidence ZIP: Apple has not certified this iPhone's signing key yet, "
        + "which needs a network connection. Share again once it is online."
    static let notMade = "Sent without the signed evidence ZIP: Malinois could not make it just now. Share again later."

    /// Pure (unit-tested): the line after a share, or nil. Only after a share that completed to a destination that takes
    /// files, for this phone's own record: when no bundle was offered for want of a certified key, or for now (the
    /// signature file, the log's comparison, a gone record not named yet), or when its making failed after the
    /// destination was picked. None for a record this phone never signed, and none without an exporter.
    static func line(readiness: EvidenceExportReadiness?, completed: Bool, destination: UIActivity.ActivityType?,
                     made: Bool?, mirrored: Bool) -> String? {
        guard completed, !mirrored, EvidenceBundleItem.takesFile(destination), let readiness else { return nil }
        switch readiness {
        case .notSigned: return nil
        case .noCertifiedKey: return noCertifiedKey
        case .notNow: return notMade
        case .ready: return made == false ? notMade : nil
        }
    }
}

/// Item 223's diagnostic (BACKLOG 223; D7 (a) of docs/design/1.13-fixes.md, the owner's of 2026-11-12): log lines only,
/// read on the owner's phone with the Console app during 1.13's TestFlight test, for the ruling on item 223's points 2
/// and 3: on which thread, and when, iOS asks for the ZIP; whether the sheet's own ask ever waits on a making; and
/// whether a share ever completes with the ZIP's making never asked for. Pure (unit-tested): the lines' words. They name
/// no record: a share's number in this launch, times since its sheet opened, and the destination, Apple's by its own
/// name and another app's not named.
enum ShareDiagnostic {
    /// A destination as the lines name it: Apple's by its own name; another app's not named, so the log does not list
    /// the apps on the phone.
    static func destination(_ type: UIActivity.ActivityType?) -> String {
        guard let name = type?.rawValue else { return "no destination named" }
        return name.hasPrefix("com.apple.") ? name : "another app's destination"
    }

    /// The sheet's own ask (`activityViewController(_:itemForActivityType:)`): its thread, its time since the sheet
    /// opened, whether a making was under way, how long it waited and whether it got the ZIP.
    static func sheetAsk(share: Int, onMain: Bool, after: Duration, destination: UIActivity.ActivityType?,
                         whileMaking: Bool, waited: Duration, got: Bool) -> String {
        "share \(share): the sheet asked for the ZIP on \(thread(onMain)), \(seconds(after)) after it opened, for "
            + "\(self.destination(destination)), \(whileMaking ? "while the ZIP was being made" : "with no ZIP being made"); "
            + "it waited \(seconds(waited)) and got \(got ? "the ZIP" : "none")"
    }

    /// The ask of the sheet's operation (`item`), once a destination is picked, the one that makes the ZIP: its thread,
    /// its time since the sheet opened, and what it got after how long.
    static func operationAsk(share: Int, onMain: Bool, after: Duration, destination: UIActivity.ActivityType?,
                             took: Duration, got: Bool) -> String {
        "share \(share): the operation asked for the ZIP on \(thread(onMain)), \(seconds(after)) after the sheet opened, "
            + "for \(self.destination(destination)); it got \(got ? "the ZIP" : "none") after \(seconds(took))"
    }

    /// The sheet's end: how it ended, and whether the ZIP's making was asked for. A share that completed to a
    /// destination that may take a file with the making never asked for (item 223's point 3) says what that cost.
    static func end(share: Int, after: Duration, completed: Bool, destination: UIActivity.ActivityType?,
                    made: Bool?) -> String {
        let making = switch made {
        case nil where completed && EvidenceBundleItem.takesFile(destination):
            "the ZIP's making was never asked for, so the share went without it and the screen said nothing"
        case nil: "the ZIP's making was never asked for"
        case true?: "the ZIP was made"
        case false?: "the ZIP could not be made"
        }
        return "share \(share): the sheet ended \(seconds(after)) after it opened, "
            + "\(completed ? "completed" : "not completed"), for \(self.destination(destination)); \(making)"
    }

    private static func thread(_ onMain: Bool) -> String { onMain ? "the main thread" : "another thread" }

    /// Seconds to the hundredth, with a point whatever the phone's language.
    private static func seconds(_ duration: Duration) -> String {
        let (whole, fraction) = duration.components
        return String(format: "%.2f s", Double(whole) + Double(fraction) / 1e18)
    }
}

extension EnvironmentValues {
    /// Makes a signed record's export bundle for Share (item 90, phase 4); nil where the app sets none (a test's screen).
    @Entry var evidenceExporter: EvidenceExporter?
}
