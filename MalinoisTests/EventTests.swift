//
//  EventTests.swift
//  MalinoisTests
//

import XCTest
@testable import Malinois

final class EventTests: XCTestCase {

    func testDuration() {
        let start = Date()
        let e = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion])
        XCTAssertEqual(e.duration, 5, accuracy: 0.001)
    }

    func testSensorSummary() {
        let e = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion, .audio])
        XCTAssertTrue(e.sensorSummary.contains("Device motion"), "the user-facing label names the phone itself moving")
        XCTAssertTrue(e.sensorSummary.contains("Sound"), "the sensor is named Sound everywhere the owner sees it")
    }

    /// Arm/disarm audit records read as monitoring state changes (not sensor events),
    /// report `isStateChange`, and decode on builds that predate the field.
    func testStateChangeEventSummaryAndBackwardCompatibleDecode() throws {
        let disarmed = Event(startDate: Date(), endDate: Date(), triggeredSensors: [],
                             cloudSyncState: .localOnly, stateChange: "disarmed")
        XCTAssertTrue(disarmed.isStateChange)
        XCTAssertEqual(disarmed.sensorSummary, "Monitoring disarmed")
        let armed = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], stateChange: "armed")
        XCTAssertEqual(armed.sensorSummary, "Monitoring armed")

        // A normal event isn't a state change.
        XCTAssertFalse(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion]).isStateChange)

        // Round-trip, and an older payload (no `stateChange` key) decodes as nil.
        let roundTrip = try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(disarmed))
        XCTAssertEqual(roundTrip.stateChange, "disarmed")
        let legacy = try JSONEncoder().encode(Event(startDate: Date(), endDate: Date(), triggeredSensors: []))
        XCTAssertNil(try JSONDecoder().decode(Event.self, from: legacy).stateChange)
    }

    /// An interruption record ("the app closed before a clean disarm" — which also covers a
    /// kill during the grace countdown or calibration, 32.R6) reads as an interruption, not a sensorless
    /// "Signal loss" (which is the jamming-blackout case) — and it decodes on builds that
    /// predate the field (nil → false).
    func testInterruptedEventSummaryAndBackwardCompatibleDecode() throws {
        let e = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], interrupted: true)
        XCTAssertTrue(e.sensorSummary.contains("interrupted"))
        XCTAssertFalse(e.sensorSummary.contains("Signal loss"))

        // Round-trip preserves it.
        let roundTrip = try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(roundTrip.interrupted, true)
        // An older payload has no `interrupted` key at all — synthesized encoding omits nil
        // optionals, so encoding an event without it reproduces exactly that shape. It must
        // decode as nil, not crash.
        let legacyData = try JSONEncoder().encode(Event(startDate: Date(), endDate: Date(), triggeredSensors: []))
        let decoded = try JSONDecoder().decode(Event.self, from: legacyData)
        XCTAssertNil(decoded.interrupted)
    }

    func testDurationSummaryLabelsFrontAndBack() {
        var e = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        e.primaryCamera = "front"; e.primaryDuration = 5
        e.secondaryCamera = "rear"; e.secondaryDuration = 5
        XCTAssertEqual(e.durationSummary, "F 5.0s · B 5.0s")
    }

    func testDurationSummaryEmptyForStills() {
        let e = Event(startDate: Date(), endDate: Date(),
                      triggeredSensors: [.motion], primaryCamera: "front")
        XCTAssertTrue(e.durationSummary.isEmpty, "stills have no clip length")
    }

    func testMetadataJSONContainsCoreFields() throws {
        let e = Event(startDate: Date(), endDate: Date().addingTimeInterval(2),
                      triggeredSensors: [.motion, .power])
        let data = try XCTUnwrap(e.metadataJSON)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, e.id.uuidString)
        // ISO8601 string round-trips to a date.
        let iso = try XCTUnwrap(obj["startDate"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: iso))
        XCTAssertEqual(Set(obj["triggeredSensors"] as? [String] ?? []), ["motion", "power"])
    }

    /// Retention: the store never exceeds the cap — it keeps the newest events and
    /// drops the oldest. Written to be robust to whatever the host already persisted.
    @MainActor
    func testEventStorePrunesToCapKeepingNewest() {
        let store = EventStore()
        let base = Date()
        let overflow = EventStore.maxEvents + 25
        var firstID: UUID?
        var lastID: UUID?
        for i in 0..<overflow {
            let e = Event(startDate: base.addingTimeInterval(Double(i)),
                          endDate: base.addingTimeInterval(Double(i)),
                          triggeredSensors: [.motion])
            if i == 0 { firstID = e.id }
            if i == overflow - 1 { lastID = e.id }
            store.add(e)
        }
        XCTAssertEqual(store.events.count, EventStore.maxEvents, "capped at the retention limit")
        XCTAssertEqual(store.events.first?.id, lastID, "newest event stays at the top")
        XCTAssertFalse(store.events.contains { $0.id == firstID }, "oldest overflow event is pruned")
    }

    /// Flood protection: a genuine tamper event must survive a flooding attack that
    /// would otherwise push it past the retention cap. Coalesced "sustained activity"
    /// (flood) events are pruned before genuine ones, so synthetic noise can't evict
    /// real evidence. The genuine event here is the OLDEST of the batch, so under naive
    /// oldest-first pruning it would be dropped — flood-first pruning must keep it.
    @MainActor
    func testFloodEventsArePrunedBeforeGenuineEvidence() {
        let store = EventStore()
        let base = Date()
        let genuine = Event(startDate: base, endDate: base, triggeredSensors: [.motion])
        store.add(genuine)   // oldest of this batch
        for i in 1...EventStore.maxEvents {
            let flood = Event(startDate: base.addingTimeInterval(Double(i)),
                              endDate: base.addingTimeInterval(Double(i)),
                              triggeredSensors: [.audio],
                              sustainedCount: 7)   // coalesced-flood marker
            store.add(flood)   // all newer than `genuine`
        }
        XCTAssertEqual(store.events.count, EventStore.maxEvents, "capped at the retention limit")
        XCTAssertTrue(store.events.contains { $0.id == genuine.id },
                      "the genuine event survives — flood events are pruned first")
    }

    /// Regression: the per-cadence stills taken *during* a flood must also count as flood
    /// records. They previously carried no `sustainedCount` at all, so both prune passes
    /// classified them as genuine, and one still per `floodCaptureInterval` filled
    /// `maxEvents` in under three hours and then evicted real events oldest-first — the very
    /// eviction the coalescing exists to prevent.
    ///
    /// The marker `captureFloodEvidence` sets is `sustainedCount: 1`, and **1 is the case
    /// that matters**: the detail label only renders "sustained ×n" for n > 1, so it is
    /// tempting to treat 1 as "not really a flood". The prune must not. The sibling test
    /// above uses 7, which is why it could not catch this.
    @MainActor
    func testFloodCadenceStillsWithCountOfOneStillPruneBeforeGenuineEvidence() {
        let store = EventStore()
        let base = Date()
        let genuine = Event(startDate: base, endDate: base, triggeredSensors: [.motion])
        store.add(genuine)   // oldest of the batch — naive oldest-first pruning would drop it
        for i in 1...EventStore.maxEvents {
            let floodStill = Event(startDate: base.addingTimeInterval(Double(i)),
                                   endDate: base.addingTimeInterval(Double(i)),
                                   triggeredSensors: [.motion],
                                   mediaFilename: "flood-\(i).jpg",   // these carry evidence
                                   sustainedCount: 1)                 // exactly what the engine sets
            store.add(floodStill)
        }
        XCTAssertEqual(store.events.count, EventStore.maxEvents, "capped at the retention limit")
        XCTAssertTrue(store.events.contains { $0.id == genuine.id },
                      "a flood still marked sustainedCount: 1 must not evict genuine evidence")
    }

    /// The half that actually catches the original defect: the engine's own flood-still
    /// factory must emit the marker. The two tests around this one pin the *prune* side —
    /// they construct the Event by hand and so would have passed throughout the bug.
    func testEngineFloodStillFactoryMarksTheRecordAsFlood() {
        let event = MonitoringEngine.makeFloodEvidenceEvent(
            sensors: [.motion, .touch], motionTrace: [], audioTrace: [],
            visionTrace: nil, offline: false)
        XCTAssertNotNil(event.sustainedCount,
                        "flood-cadence stills must carry the flood marker, or they are pruned as genuine evidence and evict real events")
        XCTAssertEqual(event.triggeredSensors, [.motion, .touch].sorted { $0.rawValue < $1.rawValue },
                       "sensors stay sorted by raw value, as every other event path does")
    }

    /// The same boundary for the media byte cap, which classifies on the identical
    /// predicate (`sustainedCount != nil` → `isFlood`) in a separate code path.
    func testMediaEvictionTreatsFloodStillsAsFloodAtCountOfOne() {
        let floodID = UUID(), genuineID = UUID()
        // Newest-first input, so the genuine event is the OLDEST and would go first
        // under a naive pass. Flood-first ordering must take the flood media instead.
        let sizes: [(id: UUID, isFlood: Bool, isSynced: Bool, bytes: Int64)] = [
            (floodID, true, false, 100),   // as produced by an Event with sustainedCount: 1
            (genuineID, false, false, 100),
        ]
        let evict = EventStore.mediaEvictionOrder(sizes: sizes, budget: 100).evict
        XCTAssertTrue(evict.contains(floodID), "flood media is evicted first")
        XCTAssertFalse(evict.contains(genuineID), "genuine media survives while flood media remains")
    }

    /// F-01: events captured while the disarm pad was open are marked owner-attributed
    /// (not deleted) once a correct PIN confirms it — the log stays append-only.
    @MainActor
    func testMarkOwnerAttributed() {
        let store = EventStore()
        let mine = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        let theirs = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        store.add(mine)
        store.add(theirs)

        store.markOwnerAttributed([mine.id])

        XCTAssertEqual(store.events.first(where: { $0.id == mine.id })?.ownerAttributed, true)
        XCTAssertNil(store.events.first(where: { $0.id == theirs.id })?.ownerAttributed,
                     "an unrelated event is untouched")
        XCTAssertTrue(store.events.contains { $0.id == theirs.id }, "marking never removes the record")
    }

    /// F-17: the byte-cap eviction drops coalesced flood media before genuine media, so
    /// a burst of synthetic clips can't evict a real event's photo to stay under budget.
    func testByteCapEvictsFloodMediaBeforeGenuine() {
        let genuineOld = UUID(), floodNewer = UUID(), genuineNewest = UUID()
        // Newest-first, each 100 bytes; budget 150 forces freeing ~2 files.
        let sizes: [(id: UUID, isFlood: Bool, isSynced: Bool, bytes: Int64)] = [
            (genuineNewest, false, false, 100),
            (floodNewer,    true,  false, 100),
            (genuineOld,    false, false, 100),
        ]
        let evict = EventStore.mediaEvictionOrder(sizes: sizes, budget: 150).evict
        XCTAssertTrue(evict.contains(floodNewer), "flood media goes first")
        XCTAssertTrue(evict.contains(genuineOld), "then the oldest genuine, to get under budget")
        XCTAssertFalse(evict.contains(genuineNewest),
                       "the newest genuine event's media is preserved even though flood media was newer")
    }

    func testByteCapNoEvictionWhenUnderBudget() {
        let sizes: [(id: UUID, isFlood: Bool, isSynced: Bool, bytes: Int64)] =
            [(UUID(), true, false, 50), (UUID(), false, true, 50)]
        XCTAssertTrue(EventStore.mediaEvictionOrder(sizes: sizes, budget: 200).evict.isEmpty)
    }

    // MARK: - Encrypted-data reset requeue (34.H13)

    /// After a reset, "synced" is true of nothing — the sanctioned exception to sync-state
    /// monotonicity flips synced FIRST-HAND events back to pending so the retry machinery
    /// re-uploads. Mirrors stay put (eighth-review M4, overturning this test's original
    /// expectation): re-publishing a mirror stamps THIS device's name on another device's
    /// evidence and can race the capturing device's own richer re-upload under `.allKeys`.
    /// The capturing device owns re-upload; a mirror is a copy, not custody.
    func testRequeueFlipsSyncedFirstHandEventsButNeverMirrors() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let synced = Event(startDate: start, endDate: start, triggeredSensors: [.motion],
                           cloudSyncState: .synced)
        let mirror = Event(startDate: start, endDate: start, triggeredSensors: [.touch],
                           cloudSyncState: .synced, sourceDevice: "Desk iPhone")
        let localOnly = Event(startDate: start, endDate: start, triggeredSensors: [.touch],
                              cloudSyncState: .localOnly)
        let result = EventStore.requeuedForReupload([synced, mirror, localOnly])
        XCTAssertEqual(result.changed, 1)
        XCTAssertEqual(result.events.first { $0.id == synced.id }?.cloudSyncState, .pending,
                       "the purged cloud copy means synced is no longer true")
        XCTAssertEqual(result.events.first { $0.id == mirror.id }?.cloudSyncState, .synced,
                       "a mirror is never re-published by this device — wrong provenance, clobber risk")
        XCTAssertEqual(result.events.first { $0.id == localOnly.id }?.cloudSyncState, .localOnly,
                       "an event that never made it up is already in the retry set")
    }

    // MARK: - Retention protects what matters most (34.H5 / 1.2)

    /// The byte cap treats synced media as a local cache (the cloud holds it; B1 can bring
    /// it back) and pending media as evidence: synced goes first, pending only in a genuine
    /// storage emergency — and every pending discard is reported so the event can record
    /// that its capture was lost BEFORE upload, not silently read as synced later.
    func testByteCapEvictsSyncedMediaBeforePendingAndReportsDiscards() {
        let pendingNewest = UUID(), syncedMid = UUID(), floodOld = UUID()
        let sizes: [(id: UUID, isFlood: Bool, isSynced: Bool, bytes: Int64)] = [
            (pendingNewest, false, false, 100),
            (syncedMid,     false, true,  100),
            (floodOld,      true,  false, 100),
        ]
        // Budget 100: flood + synced free enough — the pending capture survives.
        let mild = EventStore.mediaEvictionOrder(sizes: sizes, budget: 100)
        XCTAssertEqual(mild.evict, [floodOld, syncedMid])
        XCTAssertTrue(mild.discardedBeforeUpload.isEmpty,
                      "nothing pending was lost, so nothing is reported")
        // Budget 0: storage emergency — pending goes too, and IS reported.
        let emergency = EventStore.mediaEvictionOrder(sizes: sizes, budget: 0)
        XCTAssertEqual(emergency.evict, [floodOld, syncedMid, pendingNewest])
        XCTAssertEqual(emergency.discardedBeforeUpload, [pendingNewest],
                       "only the pending genuine capture is an evidentiary loss")
    }

    /// The count cap's eviction classes: flood first, then synced, then pending — and the
    /// arm/disarm/interruption audit rows last of all, because they are exactly what a
    /// paced attacker generating ordinary-looking events wants pushed over the boundary.
    func testCountEvictionDropsFloodThenSyncedThenPendingAndAuditLast() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID()
        // Newest-first: A pending, B audit, C synced, D flood, E pending, F synced.
        let events: [EventStore.EvictionRow] = [
            .init(id: a),
            .init(id: b, isAudit: true),
            .init(id: c, isSynced: true),
            .init(id: d, isFlood: true),
            .init(id: e),
            .init(id: f, isSynced: true),
        ]
        XCTAssertEqual(EventStore.countEvictionOrder(events: events, cap: 2), [d, f, c, e],
                       "flood, then synced oldest-first, then pending oldest-first; audit survives")
        XCTAssertEqual(EventStore.countEvictionOrder(events: events, cap: 1), [d, f, c, e, b],
                       "with the newest event exempt (39.R1.6), the audit row is the last DROPPABLE thing — the record of the incident in progress survives everything")
        XCTAssertTrue(EventStore.countEvictionOrder(events: events, cap: 6).isEmpty)
    }

    /// 39.R1.6: the count cap must never evict the event being added. At cap with no older
    /// flood rows retained — the steady state, since flood rows always evict first — the
    /// flood pass walked all the way to the newest element and evicted the just-added
    /// coalesced record AT BIRTH: the onset vanished from the log, every later count update
    /// silently no-oped against a missing id, and each cadence still wrote a Media file
    /// nothing referenced. Retention exists to shed the OLDEST; the newest event is the
    /// record of what is happening right now, and is exempt from every pass.
    func testCountEvictionNeverTakesTheNewestEvent() {
        let newFlood = UUID()
        var rows: [EventStore.EvictionRow] = [.init(id: newFlood, isFlood: true)]
        rows += (0..<3).map { _ in .init(id: UUID(), isSynced: true) }   // older synced genuine
        let evicted = EventStore.countEvictionOrder(events: rows, cap: 3)
        XCTAssertFalse(evicted.contains(newFlood),
                       "the just-added flood record must not self-evict at cap (39.R1.6)")
        XCTAssertEqual(evicted, [rows.last!.id],
                       "the oldest synced row — a cloud-recoverable cache copy — goes instead")
    }

    /// Fourth-pass R3-4, the eviction half: mirrors are copies — the capturing device and
    /// the cloud still hold them, and a re-fetch brings them back — so they evict before
    /// ANY first-hand class. Without this, bulk-inserted future-dated mirrors at cap pushed
    /// out genuine evidence and its local media: iCloud credentials reaching on-device
    /// evidence, exactly what tier-2 promises they cannot do.
    func testCountEvictionTakesMirrorsBeforeAnyFirstHandClass() {
        let newest = UUID(), mirror1 = UUID(), flood = UUID(), synced = UUID(), mirror2 = UUID()
        // Newest-first: a genuine pending capture, then a "fresh" mirror, a flood row,
        // a synced genuine, and an old mirror.
        let rows: [EventStore.EvictionRow] = [
            .init(id: newest),
            .init(id: mirror1, isSynced: true, isMirrored: true),
            .init(id: flood, isFlood: true),
            .init(id: synced, isSynced: true),
            .init(id: mirror2, isSynced: true, isMirrored: true),
        ]
        XCTAssertEqual(EventStore.countEvictionOrder(events: rows, cap: 3), [mirror2, mirror1],
                       "both mirrors go — oldest first — before flood or synced first-hand rows")
        XCTAssertEqual(EventStore.countEvictionOrder(events: rows, cap: 2), [mirror2, mirror1, flood],
                       "only once the mirrors are exhausted does the first-hand order resume")
        // A wall of future-dated mirrors above genuine evidence: the genuine rows survive.
        let genuine = UUID()
        var wall: [EventStore.EvictionRow] =
            (0..<4).map { _ in .init(id: UUID(), isSynced: true, isMirrored: true) }   // "newest" fabricated mirrors
        wall.append(.init(id: genuine, isSynced: true))               // the oldest row: real evidence
        XCTAssertFalse(EventStore.countEvictionOrder(events: wall, cap: 2).contains(genuine),
                       "fabricated mirrors sorted above real evidence must evict themselves, not it")
    }

    /// 39.R1.6 + 31.F14: the launch sweep reclaims Media files nothing references — but
    /// deleting evidence by mistake is unforgivable, so the rule refuses wholesale while a
    /// corrupt-log backup exists (unreferenced media may be real evidence whose metadata was
    /// lost — F-11's backup is the tombstone), and leaves young files alone (a capture is
    /// stored moments before its event update lands; the sweep must never race that window).
    func testOrphanSweepTakesOnlyOldUnreferencedFilesAndRefusesAfterCorruption() {
        let now = Date()
        let old = now.addingTimeInterval(-172_800)     // two days
        let young = now.addingTimeInterval(-60)
        let onDisk = [(name: "a.jpg", modified: old),
                      (name: "b.jpg", modified: old),
                      (name: "c.mov", modified: young),
                      (name: "d.mov", modified: now.addingTimeInterval(3600))]   // future-dated
        XCTAssertEqual(EventStore.orphanedMediaNames(onDisk: onDisk, referenced: ["b.jpg"],
                                                     corruptBackupPresent: false, now: now),
                       ["a.jpg"],
                       "old + unreferenced is swept; referenced, young, and future-dated are not")
        XCTAssertTrue(EventStore.orphanedMediaNames(onDisk: onDisk, referenced: [],
                                                    corruptBackupPresent: true, now: now).isEmpty,
                      "a corrupt-log backup on disk means orphans may be evidence — refuse wholesale")
        XCTAssertTrue(EventStore.orphanedMediaNames(onDisk: [], referenced: [],
                                                    corruptBackupPresent: false, now: now).isEmpty)
    }

    // MARK: - Device-label fallback is the model name (owner's call, 2026-08-30)

    /// iOS reports a generic "iPhone" to apps, so an unlabeled device's mirrors were
    /// anonymous. The fallback is now the marketing name via a table generated from the
    /// SDK's own device-type registry; unknown identifiers pass through unchanged — honest
    /// beats guessed — and an empty identifier degrades to plain "iPhone".
    func testMarketingNameMapsKnownModelsAndPassesUnknownsThrough() {
        XCTAssertEqual(DeviceInfo.marketingName(forIdentifier: "iPhone18,4"), "iPhone Air")
        XCTAssertEqual(DeviceInfo.marketingName(forIdentifier: "iPhone18,1"), "iPhone 17 Pro")
        XCTAssertEqual(DeviceInfo.marketingName(forIdentifier: "iPhone12,8"),
                       "iPhone SE (2nd generation)")
        XCTAssertEqual(DeviceInfo.marketingName(forIdentifier: "iPhone19,9"), "iPhone19,9",
                       "an unknown identifier passes through — honest beats guessed")
        XCTAssertEqual(DeviceInfo.marketingName(forIdentifier: ""), "iPhone")
    }

    // MARK: - Media manifest (34's metadataJSON item + B1's robustness note)

    /// The manifest and the exfiltrator's record names share one token rule
    /// (`primaryMediaToken`/`secondaryMediaToken`), so the payload can never claim records
    /// the uploader didn't create — the one-value-two-readers class this codebase keeps
    /// re-learning, pinned here instead.
    func testMediaManifestMatchesTheUploadTokenRule() {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        XCTAssertTrue(event.mediaManifest.isEmpty, "no media, no manifest")

        event.mediaFilename = "a.jpg"
        XCTAssertEqual(event.mediaManifest, ["primary"],
                       "no camera recorded — the uploader's fallback token, exactly")

        event.primaryCamera = "front"
        event.secondaryMediaFilename = "b.jpg"
        event.secondaryCamera = "rear"
        XCTAssertEqual(event.mediaManifest, ["front", "rear"])
        XCTAssertEqual(event.primaryMediaToken, "front")
        XCTAssertEqual(event.secondaryMediaToken, "rear")
    }

    // MARK: - Write-ahead journal (H4 / 31.F3; ADR 0005)

    /// The journal's contract in two pure functions: an event encodes to exactly one line
    /// (compact JSON never emits a raw newline — the invariant line-splitting rests on),
    /// and lines decode back losslessly by id.
    func testJournalLinesRoundTripOneEventPerLine() throws {
        let birth = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion, .power])
        let audit = Event(startDate: Date(), endDate: Date(), triggeredSensors: [],
                          cloudSyncState: .pending, stateChange: "armed")
        let lines = [try XCTUnwrap(EventStore.journalLine(for: birth)),
                     try XCTUnwrap(EventStore.journalLine(for: audit))]
        for line in lines {
            XCTAssertEqual(line.last, 0x0A, "every line ends in exactly one newline")
            XCTAssertFalse(line.dropLast().contains(0x0A), "no interior newline — one event, one line")
        }
        let recovered = EventStore.journaledEvents(in: lines[0] + lines[1])
        XCTAssertEqual(recovered.map(\.id), [birth.id, audit.id])
    }

    /// An append the kill cut mid-write — the file's whole reason to exist — leaves a torn
    /// final line; neither it nor a garbage line may void the intact entries around them.
    func testJournalParseSkipsGarbageAndTornLines() throws {
        let good = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.audio])
        let goodLine = try XCTUnwrap(EventStore.journalLine(for: good))
        var data = Data("not json at all\n".utf8)
        data.append(goodLine)
        data.append(goodLine.dropLast(12))   // torn: cut mid-write, no trailing newline
        XCTAssertEqual(EventStore.journaledEvents(in: data).map(\.id), [good.id],
                       "the intact line survives; garbage and the torn tail are skipped")
    }

    /// The discard marker round-trips and decodes as nil on events saved before it existed.
    func testMediaDiscardedBackwardCompatibleDecode() throws {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        XCTAssertNil(try JSONDecoder().decode(Event.self,
                     from: JSONEncoder().encode(event)).mediaDiscarded)
        event.mediaDiscarded = true
        XCTAssertEqual(try JSONDecoder().decode(Event.self,
                       from: JSONEncoder().encode(event)).mediaDiscarded, true)
    }

    /// New optional field decodes fine on events saved before it existed (nil → false).
    func testOwnerAttributedBackwardCompatibleDecode() throws {
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","startDate":0,"endDate":0,"triggeredSensors":["motion"],\
        "motionTrace":[],"audioTrace":[],"cloudSyncState":"pending"}
        """.utf8)
        let e = try JSONDecoder().decode(Event.self, from: legacy)
        XCTAssertNil(e.ownerAttributed)
    }

    // MARK: - Merging mirrored evidence from iCloud (BACKLOG 9b)

    private func event(_ id: UUID, at seconds: TimeInterval, from device: String? = nil) -> Event {
        let t = Date(timeIntervalSince1970: seconds)
        return Event(id: id, startDate: t, endDate: t, triggeredSensors: [.motion],
                     sourceDevice: device)
    }

    /// **The safety property the whole feature rests on.** A fetch may only ever ADD. If an
    /// incoming copy shares an id with an event already in the log, the local one is kept
    /// untouched — first-hand evidence captured on this device outranks a claim arriving over
    /// the network, and an update path is precisely where a merge bug could damage real
    /// evidence. This is also what stops a device re-fetching its own uploads and duplicating
    /// its entire log every refresh.
    func testMergeNeverOverwritesOrDuplicatesAnExistingEvent() {
        let sharedID = UUID()
        let local = [event(sharedID, at: 100)]                      // captured here, media on disk
        let incoming = [event(sharedID, at: 100, from: "iPad")]     // the same event, mirrored back

        let merged = EventStore.merged(local: local, incoming: incoming)
        XCTAssertEqual(merged.count, 1, "the same event must not appear twice")
        XCTAssertNil(merged.first?.sourceDevice,
                     "the LOCAL copy wins — a mirror must never overwrite first-hand evidence")
    }

    // MARK: - Monotonic updates and mirror enrichment survival (reviews 6/8: F2 + M3)

    /// Sixth-review F2: `respond()` holds a pre-capture value copy across the whole capture;
    /// a disarm meanwhile attributes the STORED copy. The write-back of the stale copy must
    /// not erase that — attribution is monotonic at true.
    @MainActor
    func testUpdatePreservesOwnerAttributionSetMidCapture() {
        let store = EventStore()
        let e = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        store.add(e)
        store.markOwnerAttributed([e.id])

        var stale = e                      // the pre-capture copy: no attribution
        stale.mediaFilename = "clip.mov"   // capture completed, media attached
        store.update(stale)

        let stored = store.events.first { $0.id == e.id }
        XCTAssertEqual(stored?.ownerAttributed, true,
                       "the disarm's attribution must survive the capture's whole-value write-back")
        XCTAssertEqual(stored?.mediaFilename, "clip.mov", "the capture's own fields still land")
    }

    /// The `.synced` half of the same rule: a whole-value update used to bypass the
    /// `setSyncState` monotonic guard entirely.
    @MainActor
    func testUpdatePreservesSyncedStateAgainstStaleCopy() {
        let store = EventStore()
        let e = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        store.add(e)
        store.setSyncState(.synced, for: e.id)

        let stale = e                      // still .pending from creation
        store.update(stale)

        XCTAssertEqual(store.events.first { $0.id == e.id }?.cloudSyncState, .synced,
                       "a stale copy's write-back must not walk a synced event back to pending")
    }

    /// Eighth-review M3: a mirror the owner downloaded full evidence onto is later superseded
    /// by a higher-revision cloud copy — whose `mediaFilename` is nil by construction. The
    /// downloaded file's reference must survive the supersede, or the orphan sweep deletes it.
    func testSupersedingMirrorKeepsDownloadedMedia() {
        let id = UUID()
        var enriched = event(id, at: 100, from: "iPhone Air")
        enriched.cloudRevision = 2
        enriched.mediaFilename = "downloaded.jpg"

        var incoming = event(id, at: 100, from: "iPhone Air")
        incoming.cloudRevision = 3        // later revision, no media by construction

        let merged = EventStore.merged(local: [enriched], incoming: [incoming])
        XCTAssertEqual(merged.first?.cloudRevision, 3, "the later revision must still supersede")
        XCTAssertEqual(merged.first?.mediaFilename, "downloaded.jpg",
                       "locally-downloaded evidence must survive the supersede")
    }

    func testMergeAddsUnseenEventsNewestFirst() {
        let older = UUID(), newer = UUID(), local = UUID()
        let merged = EventStore.merged(
            local: [event(local, at: 200)],
            incoming: [event(older, at: 100, from: "iPad"), event(newer, at: 300, from: "iPad")])

        XCTAssertEqual(merged.map(\.id), [newer, local, older],
                       "merged log stays newest-first regardless of fetch order")
        XCTAssertEqual(merged.filter(\.isMirrored).count, 2)
    }

    /// A server returning the same record twice in one page must not produce two log entries.
    func testMergeDedupesWithinTheIncomingBatch() {
        let id = UUID()
        let merged = EventStore.merged(
            local: [], incoming: [event(id, at: 100, from: "iPad"), event(id, at: 100, from: "iPad")])
        XCTAssertEqual(merged.count, 1)
    }

    /// The restore case: a reinstall starts with an empty log, so everything mirrored comes
    /// back — and every one of them is marked as a copy, because the media did not come with it.
    func testMergeIntoAnEmptyLogRestoresEverythingAsMirrored() {
        let merged = EventStore.merged(
            local: [], incoming: [event(UUID(), at: 100, from: "iPhone"), event(UUID(), at: 200, from: "iPhone")])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.allSatisfy(\.isMirrored))
    }

    func testMergeWithNothingNewLeavesTheLogIdentical() {
        let id = UUID()
        let local = [event(id, at: 100)]
        XCTAssertEqual(EventStore.merged(local: local, incoming: [event(id, at: 100, from: "iPad")]).map(\.id),
                       local.map(\.id))
        XCTAssertEqual(EventStore.merged(local: local, incoming: []).map(\.id), local.map(\.id))
    }

    // MARK: - The Event Log's "not yet synced" count (BACKLOG 8 follow-up)

    private func ev(_ state: CloudSyncState, stateChange: String? = nil) -> Event {
        Event(id: UUID(),
              startDate: Date(timeIntervalSince1970: 1_700_000_000),
              endDate: Date(timeIntervalSince1970: 1_700_000_003),
              triggeredSensors: stateChange == nil ? [.motion] : [],
              cloudSyncState: state,
              stateChange: stateChange)
    }

    /// Regression for a claim that went stale rather than a bug that was written: arm/disarm
    /// records were excluded from this count because they "never sync", which was true until
    /// BACKLOG 8 began pushing the audit trail. While the exclusion stood, a disarm record
    /// that failed to upload produced no warning anywhere — and that is the upload failure
    /// that matters most, since the cloud copy is the only reason a disarm entry survives an
    /// attacker who deletes the app.
    func testArmDisarmRecordsCountTowardTheUnsyncedBanner() {
        let events = [ev(.synced), ev(.pending, stateChange: "disarmed"), ev(.localOnly, stateChange: "armed")]
        XCTAssertEqual(EventStore.unsyncedCount(in: events), 2,
                       "a state change that never reached iCloud has to be visible as such")
    }

    func testFullySyncedLogReportsNothingOutstanding() {
        let events = [ev(.synced), ev(.synced, stateChange: "armed"), ev(.synced, stateChange: "disarmed")]
        XCTAssertEqual(EventStore.unsyncedCount(in: events), 0,
                       "synced arm/disarm rows must not keep the banner up forever")
    }

    /// The badge text is user-facing copy, and "Cloud" was ambiguous about *whose* cloud — the
    /// one thing this app is at pains to be clear about, since there is no developer server.
    func testSyncBadgeNamesTheDestinationExplicitly() {
        XCTAssertEqual(CloudSyncState.synced.displayName, "iCloud synced")
        XCTAssertEqual(CloudSyncState.pending.displayName, "Syncing…")
        XCTAssertEqual(CloudSyncState.localOnly.displayName, "Local only")
    }

    // MARK: - Unlock reconciliation (external review 2026-08-26, finding 1)

    private func logEntry(_ minutesAgo: Int, stateChange: String? = nil) -> Event {
        let t = Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60)
        return Event(startDate: t, endDate: t, triggeredSensors: stateChange == nil ? [.motion] : [],
                     stateChange: stateChange)
    }

    /// The data-loss path this replaces: a force-quit followed by a background launch before
    /// first unlock. The engine is constructed, logs an interrupted-session event, and the log
    /// on disk is still encrypted and unread — so the in-memory array is non-empty when the
    /// device unlocks. The old reconciliation kept ONLY those in-memory entries and let the next
    /// write put them over the entire historical log.
    func testUnlockKeepsBothTheDiskLogAndWhatWasQueuedWhileLocked() {
        let disk = [logEntry(10), logEntry(20), logEntry(30)]
        let queued = [logEntry(1, stateChange: "interrupted")]

        let out = EventStore.reconciledAfterUnlock(disk: disk, queued: queued)

        XCTAssertEqual(Set(out.map(\.id)), Set((disk + queued).map(\.id)),
                       "no first-hand record may be dropped from either side")
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out.first?.id, queued[0].id, "newest first, like the rest of the log")
    }

    /// A queued entry that already reached disk must not double up.
    func testUnlockReconciliationDoesNotDuplicateAnEntryPresentOnBothSides() {
        let shared = logEntry(5)
        let out = EventStore.reconciledAfterUnlock(disk: [shared, logEntry(60)], queued: [shared])
        XCTAssertEqual(out.count, 2)
    }

    /// The ordinary case — nothing was added while locked — still yields exactly the disk log.
    func testUnlockWithNothingQueuedYieldsTheDiskLogUnchanged() {
        let disk = [logEntry(10), logEntry(20)]
        XCTAssertEqual(EventStore.reconciledAfterUnlock(disk: disk, queued: []).map(\.id),
                       disk.map(\.id))
    }

    // MARK: - Clip protection transaction (34-review B3)

    private struct StubProtectionError: Error {}

    /// If the protection attribute cannot be applied to a just-moved clip, the file must be
    /// removed before the error propagates — otherwise the store reports "not stored" while
    /// an untracked clip sits on disk at the temp file's weaker protection, invisible to the
    /// byte cap and the sweeper.
    func testAClipWhoseProtectionFailsIsRemovedNotAbandoned() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("b3-\(UUID().uuidString).mov")
        try Data([0x01]).write(to: dest)
        XCTAssertThrowsError(try EventStore.applyClipProtectionOrRemove(at: dest) { _ in
            throw StubProtectionError()
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "the failed clip must not be left behind")
    }

    func testAClipWhoseProtectionSucceedsIsKept() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("b3-\(UUID().uuidString).mov")
        try Data([0x01]).write(to: dest)
        defer { try? FileManager.default.removeItem(at: dest) }
        try EventStore.applyClipProtectionOrRemove(at: dest) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - Orphaned-clip sweeper scope (34-review P3)

    /// The sweeper's comment always said "only our own UUID-named clips"; the code deleted
    /// every sufficiently old .mov in tmp. The UUID check is now enforced.
    func testSweeperOnlyTouchesUUIDNamedClips() throws {
        let tmp = FileManager.default.temporaryDirectory
        let ours = tmp.appendingPathComponent(UUID().uuidString + ".mov")
        let foreign = tmp.appendingPathComponent("not-a-uuid-\(Int.random(in: 0..<1_000_000)).mov")
        try Data([0x01]).write(to: ours)
        try Data([0x01]).write(to: foreign)
        defer { try? FileManager.default.removeItem(at: foreign) }
        CameraController.sweepOrphanedClips(olderThan: -1)   // negative age: everything is old enough
        XCTAssertFalse(FileManager.default.fileExists(atPath: ours.path), "our orphan is swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path),
                      "a file the app didn't name is never deleted")
    }

    // MARK: - Sync-state monotonicity (34-review H9)

    /// Several retry paths can race one event; a late duplicate's failure must not walk an
    /// already-synced event back to pending/local-only — the record is on the server.
    func testSyncStateNeverLeavesSyncedImplicitly() {
        XCTAssertFalse(EventStore.mayTransitionSyncState(from: .synced, to: .pending))
        XCTAssertFalse(EventStore.mayTransitionSyncState(from: .synced, to: .localOnly))
        XCTAssertTrue(EventStore.mayTransitionSyncState(from: .synced, to: .synced))
        XCTAssertTrue(EventStore.mayTransitionSyncState(from: .pending, to: .synced))
        XCTAssertTrue(EventStore.mayTransitionSyncState(from: .pending, to: .localOnly))
        XCTAssertTrue(EventStore.mayTransitionSyncState(from: .localOnly, to: .pending),
                      "a retry may reopen a local-only event on reconnect")
    }

    // MARK: - Merge persistence (34-review H8)

    /// A mirror superseded by a later revision of itself keeps the event COUNT identical —
    /// and the old count-keyed persist guard skipped the write, so the F5 enrichment repair
    /// lived only in memory and evaporated at the next launch. What a merge CHANGED decides.
    func testAnEnrichmentOnlyMergeReportsAnUpdate() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sparse = Event(id: id, startDate: start, endDate: start, triggeredSensors: [.motion],
                           cloudSyncState: .synced, sourceDevice: "Desk iPhone", cloudRevision: 1)
        let rich = Event(id: id, startDate: start, endDate: start.addingTimeInterval(4),
                         triggeredSensors: [.motion], thumbnailData: Data([0xAB]),
                         cloudSyncState: .synced, sourceDevice: "Desk iPhone", cloudRevision: 2)
        let after = EventStore.merged(local: [sparse], incoming: [rich])
        let changes = EventStore.mergeChanges(from: [sparse], to: after)
        XCTAssertEqual(changes.inserted, 0)
        XCTAssertEqual(changes.updated, 1, "the enrichment is a change and must persist")
        // A merge that changes nothing reports nothing — no spurious disk writes.
        let again = EventStore.mergeChanges(from: after,
                                            to: EventStore.merged(local: after, incoming: [rich]))
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.updated, 0)
    }

    // MARK: - Corruption tombstones age out (seventh-review #6)

    /// One corrupt-log backup used to disable the orphan sweep FOREVER. The refusal is now
    /// time-bounded: newest three kept within a month, everything else reaped - and a
    /// future-dated stamp reads as young (the sweep's own clock-weirdness rule).
    func testReapableCorruptArtifactsKeepsNewestThreeForAMonth() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = 86_400.0
        let stamps: [(name: String, date: Date)] = [
            ("old", now.addingTimeInterval(-45 * day)),      // past the month: reaped
            ("d3", now.addingTimeInterval(-3 * day)),
            ("d2", now.addingTimeInterval(-2 * day)),
            ("d1", now.addingTimeInterval(-1 * day)),
            ("d4", now.addingTimeInterval(-4 * day)),        // young but 4th-newest: reaped
            ("future", now.addingTimeInterval(5 * day))      // clock weirdness: young, and newest
        ]
        let reaped = Set(EventStore.reapableCorruptArtifacts(stamps: stamps, now: now))
        XCTAssertEqual(reaped, ["old", "d4", "d3"],
                       "45d-old ages out; the 4th/5th-newest go; newest three (future, d1, d2) survive")

        XCTAssertTrue(EventStore.reapableCorruptArtifacts(
            stamps: [("lone", now.addingTimeInterval(-31 * day))], now: now).contains("lone"),
            "even a lone tombstone ages out after the month - the sweep must resume eventually")
        XCTAssertTrue(EventStore.reapableCorruptArtifacts(stamps: [], now: now).isEmpty)
    }

    func testCorruptArtifactDateParsesEmbeddedStamp() {
        XCTAssertEqual(EventStore.corruptArtifactDate("events.corrupt-1700000000.json"),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(EventStore.corruptArtifactDate("com.malinois.settings.corrupt-42"),
                       Date(timeIntervalSince1970: 42))
        XCTAssertNil(EventStore.corruptArtifactDate("events.corrupt-.json"), "no digits, no date")
        XCTAssertNil(EventStore.corruptArtifactDate("events.json"), "not a tombstone at all")
    }
}
