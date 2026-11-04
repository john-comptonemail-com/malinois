//
//  EvidenceBundleItem.swift
//  Malinois
//
//  The export bundle as an item of the share sheet (BACKLOG item 90, phase 4; ADR 0067). The sheet opens at once, as
//  before; the bundle is made only when the owner picks where to send it, so a share cancelled spends no signature,
//  and removed once the sheet is gone. Only the sheet's operation for the destination picked makes it: iOS asks the
//  sheet's items as soon as it opens, before anything is picked, and those asks get only a bundle already made (the
//  device check of 2026-10-31). A bundle that cannot be made is left out, and the sentence and the media go as before.
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

    /// What a task waited for made: written before its semaphore's signal, read after the wait.
    private final class Made: @unchecked Sendable {
        var url: URL?
    }

    private let make: @Sendable () async -> URL?
    private let state = Mutex<State>(.waiting)

    /// - Parameters:
    ///   - placeholder: where the bundle's ZIP will be, by name: the sheet reads only its kind, a file.
    ///   - make: makes the bundle and returns its ZIP, in a folder of its own; nil when it cannot.
    init(placeholder: URL, make: @escaping @Sendable () async -> URL?) {
        self.make = make
        super.init(placeholderItem: placeholder)
    }

    /// The bundle Share offers for `record`, with `log` as the app holds it: one only for a record this phone signed,
    /// once the signer has compared the log on disk in this launch (item 182, codex-3 on 68bd96b3), and while a key can
    /// sign its export statement (item 187, deepseek-1); nil without an exporter (a test's screen).
    static func forShare(of record: Event, log: [Event], exporter: EvidenceExporter?) async -> EvidenceBundleItem? {
        guard let exporter, await exporter.signer.canExport(record.id) else { return nil }
        let placeholder = exporter.temporaryDirectory.appendingPathComponent(EvidenceExporter.bundleName(for: record) + ".zip")
        return EvidenceBundleItem(placeholder: placeholder) { try? await exporter.bundle(of: record, log: log) }
    }

    /// Called on a secondary thread once the owner picks where to send the share, the destination in `activityType`: the
    /// only place the bundle is made. It may not be nil: a bundle not made has its placeholder here, and the sheet's ask
    /// below leaves it out.
    override var item: Any {
        if let bundle = madeBundle(for: activityType) { return bundle }
        return placeholderItem ?? NSNull()
    }

    /// The sheet's own ask for the item, on the main thread: the bundle its operation made for the destination picked, or
    /// nil to leave it out. It never makes one: iOS asks as soon as the sheet opens, before any destination is picked,
    /// and a bundle made then spent a signature on a sheet that might be cancelled, the main thread held meanwhile.
    override func activityViewController(_ activityViewController: UIActivityViewController,
                                         itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        keptBundle(for: activityType)
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
    private static func takesFile(_ destination: UIActivity.ActivityType?) -> Bool {
        guard let destination else { return true }
        return !destinationsWithoutFiles.contains(destination)
    }

    /// The bundle's ZIP, made the first time it is asked for and kept; nil when it could not be made or the share is over.
    /// Whoever asks while it is being made waits for it, so it is made once.
    func madeBundle() -> URL? {
        state.withLock { state -> URL? in
            switch state {
            case .made(let url):
                return url
            case .finished:
                return nil
            case .waiting:
                let url = Self.wait(for: make)
                state = .made(url)
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

    /// Runs `make` to its end on a thread that may wait: the sheet's own, off the main thread. At that thread's priority,
    /// so the sheet never waits on work of a lower one.
    private static func wait(for make: @escaping @Sendable () async -> URL?) -> URL? {
        let done = DispatchSemaphore(value: 0)
        let made = Made()
        Task.detached(priority: Task.currentPriority) {
            made.url = await make()
            done.signal()
        }
        done.wait()
        return made.url
    }
}

extension EnvironmentValues {
    /// Makes a signed record's export bundle for Share (item 90, phase 4); nil where the app sets none (a test's screen).
    @Entry var evidenceExporter: EvidenceExporter?
}
