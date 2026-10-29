//
//  Item163RecordCapsTests.swift
//  MalinoisTests
//
//  1.8.2's step 32 (item 152's leads 9 to 12 and 20): what a record from iCloud may carry. A writer of the owner's
//  private database other than this app (none exists today: the container has no API token) could make one copy in
//  the log far larger than a real one: a media list or a tripwire list naming one entry thousands of times, a
//  "thumbnail" the size of a photo, a device name of one letter and endless accent marks (one character), a status
//  kind whose number is padded with zeros. Each is held to what a real record carries. Also: a fetch that brings
//  nothing new leaves the binding file alone, and a download into this iPhone's own record asks iCloud only for the
//  names its own upload used.
//

import XCTest
import CloudKit
import UIKit
@testable import Malinois

@MainActor
final class Item163RecordCapsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem163Caps")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func metaRecord(metadata: [String: Any]? = nil, sensors: String? = nil) throws -> CKRecord {
        let record = CKRecord(recordType: CloudExfiltrator.metaRecordTypeV2)
        record.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
        record.encryptedValues["startDate"] = Date() as CKRecordValue
        if let sensors { record.encryptedValues["triggeredSensors"] = sensors as CKRecordValue }
        if let metadata {
            let json = try JSONSerialization.data(withJSONObject: metadata)
            record.encryptedValues["metadataJSON"] = try XCTUnwrap(String(bytes: json, encoding: .utf8)) as CKRecordValue
        }
        return record
    }

    // MARK: - Lists (leads 11 and 12)

    /// A media list naming one camera fifty thousand times keeps each name once, in the order it first came: never
    /// more than the four names a record can carry, nor more than eight record names for a download to ask for.
    func testAMediaListKeepsEachNameOnce() throws {
        let media = Array(repeating: "front", count: 50_000) + ["rear", "front", "rear"]
        let event = try XCTUnwrap(CloudExfiltrator.event(from: try metaRecord(metadata: ["media": media])))
        XCTAssertEqual(event.cloudMediaManifest, ["front", "rear"], "each name once, in the order it first came")
        let names = CloudExfiltrator.fullMediaRecordNames(for: event.id, manifest: event.cloudMediaManifest)
        XCTAssertEqual(names.count, 4, "two cameras, two record generations")
        XCTAssertLessThanOrEqual(names.count, 2 * CloudExfiltrator.allowedMediaTokens.count)
    }

    /// A tripwire list naming one tripwire fifty thousand times keeps each tripwire once: never more than there are.
    func testATripwireListKeepsEachTripwireOnce() throws {
        let sensors = Array(repeating: "motion", count: 50_000).joined(separator: ",") + ",power,motion"
        let event = try XCTUnwrap(CloudExfiltrator.event(from: try metaRecord(sensors: sensors)))
        XCTAssertEqual(event.triggeredSensors, [.motion, .power], "each tripwire once, in the decoder's order")
        XCTAssertLessThanOrEqual(event.triggeredSensors.count, SensorType.allCases.count)
    }

    // MARK: - Thumbnails and device names (lead 9)

    /// A "thumbnail" of 100 KiB is not one: every thumbnail this app makes is a JPEG of at most 200 pixels, about
    /// 21 KB at the very most (pure noise), so the copy keeps none.
    func testAThumbnailFiveTimesTheLargestRealOneIsDropped() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data(count: 100 * 1_024).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let record = try metaRecord()
        record["thumbnail"] = CKAsset(fileURL: file)
        XCTAssertNil(CloudExfiltrator.event(from: record)?.thumbnailData, "a 100 KiB thumbnail is not one")
    }

    /// The control: the largest thumbnails this app can make, a 200-pixel picture of pure noise as a still's thumbnail
    /// (JPEG quality 0.4) and as a clip's (0.5), fit the limit twice over, so no real thumbnail is dropped.
    func testTheLargestRealThumbnailsFitTheLimitTwice() throws {
        let noise = Self.noiseImage(side: 200)
        let still = try XCTUnwrap(noise.jpegData(compressionQuality: 1), "a still of pure noise")
        let stillThumbnail = try XCTUnwrap(CameraController.thumbnail(from: still))
        let clipThumbnail = try XCTUnwrap(noise.jpegData(compressionQuality: 0.5), "a clip's thumbnail is its frame at 0.5")
        for (what, size) in [("still", stillThumbnail.count), ("clip", clipThumbnail.count)] {
            XCTAssertLessThanOrEqual(2 * size, CloudExfiltrator.maxThumbnailBytes, "a \(what)'s noise thumbnail is \(size) bytes")
        }
    }

    /// A device name of one letter and a hundred thousand accent marks is one character, so the 64-character limit
    /// kept all 200 KB of it. Names are held in bytes as well, cut between characters; a name with nothing left reads
    /// as "another device", as an empty one does.
    func testADeviceNameIsHeldInBytesAsWellAsCharacters() {
        let accented = "e" + String(repeating: "\u{301}", count: 100_000)
        XCTAssertEqual(CloudExfiltrator.sanitizedDeviceName(accented), "another device", "one character of 200 KB")
        let heavy = String(repeating: "e" + String(repeating: "\u{301}", count: 50), count: 64)
        let kept = CloudExfiltrator.sanitizedDeviceName(heavy)
        XCTAssertLessThanOrEqual(kept.utf8.count, CloudExfiltrator.maxDeviceNameBytes, "held in bytes")
        XCTAssertFalse(kept.isEmpty)
        XCTAssertTrue(heavy.hasPrefix(kept), "cut between characters")
        // The controls: the most a phone sends (40 characters) of a 25-byte emoji, and an ordinary name.
        let family = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 40)
        XCTAssertEqual(family.count, 40)
        XCTAssertEqual(CloudExfiltrator.sanitizedDeviceName(family), family, "1,000 bytes, kept whole")
        XCTAssertEqual(CloudExfiltrator.sanitizedDeviceName("Kitchen iPad"), "Kitchen iPad")
    }

    // MARK: - Status kinds

    /// A status kind's number padded with zeros, or signed with a plus, read as the same number, so a clock-change or
    /// resume kind could carry a megabyte of zeros into the log: such a kind is dropped. The kinds this app writes pass.
    func testAStatusKindWithAPaddedNumberIsDropped() {
        func decoded(_ kind: String) -> Event? {
            let record = CKRecord(recordType: CloudExfiltrator.stateRecordTypeV2)
            record.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
            record.encryptedValues["startDate"] = Date() as CKRecordValue
            record.encryptedValues["kind"] = kind as CKRecordValue
            return CloudExfiltrator.stateEvent(from: record)
        }
        let zeros = String(repeating: "0", count: 100_000)
        for padded in ["clockChanged.\(zeros)60", "clockChanged.+60", "clockChanged.060", "clockChanged.-060",
                       "resumed.\(zeros)252", "resumed.+252", "resumed.0252"] {
            XCTAssertNil(decoded(padded), "dropped: \(padded.prefix(20))… (\(padded.utf8.count) bytes)")
        }
        for written in [Event.clockChangeKind(seconds: 60), Event.clockChangeKind(seconds: -180),
                        Event.resumedKind(seconds: 252)] {
            XCTAssertEqual(decoded(written)?.stateChange, written, "a kind this app writes still passes")
        }
    }

    // MARK: - The binding file (lead 20)

    private final class Writes { var count = 0 }

    /// A fetch that brings nothing new leaves the binding file as it is: each write reaches the storage medium (step
    /// 18's full sync), and every push from iCloud runs a fetch.
    func testAFetchThatBringsNothingNewWritesNothing() async throws {
        let writes = Writes()
        let file = (EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        let gate = CloudEnrollment(file: file, authenticate: { _ in true }, persist: { data, url in
            writes.count += 1
            try CloudEnrollment.write(data, to: url)
        })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let lease = try XCTUnwrap(gate.authorize(account: "account-a"))
        func copy() -> Event { Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], sourceDevice: "iPhone Air") }
        let copies = [copy(), copy(), copy()]
        let before = writes.count
        XCTAssertTrue(gate.registerRemoteEvents(copies, lease: lease))
        XCTAssertEqual(writes.count, before + 1, "three new copies bound in one write")
        XCTAssertTrue(gate.registerRemoteEvents(copies, lease: lease), "the same fetch again is accepted")
        XCTAssertEqual(writes.count, before + 1, "and writes nothing")
        let another = copy()
        XCTAssertTrue(gate.registerRemoteEvents(copies + [another], lease: lease))
        XCTAssertEqual(writes.count, before + 2, "one new copy, one write")
        XCTAssertTrue(gate.authorizeRecord(another.id, lease: lease), "and the new copy is bound")
    }

    // MARK: - A download into this iPhone's own record (lead 10)

    /// iCloud as another writer could leave it: a still under every name a download can ask for. Like iCloud, the
    /// stand-in answers only the names asked for (every name when no list is given), and it notes what was asked.
    private final class PlantedCloud {
        var asked: [[String]?] = []
        let file: URL
        init(file: URL) { self.file = file }
        func fetch(_ manifest: [String]?) -> CloudExfiltrator.FullMediaFetch {
            asked.append(manifest)
            let names = manifest ?? ["front", "rear", "primary", "secondary"]
            return CloudExfiltrator.FullMediaFetch(
                media: names.map { name in
                    CloudExfiltrator.FetchedMedia(slot: name, camera: ["front", "rear"].contains(name) ? name : nil,
                                                  fileURL: file)
                },
                complete: true)
        }
    }

    private func engineWithPlantedCloud() throws -> (EventStore, MonitoringEngine, PlantedCloud) {
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem163Caps-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let cloud = PlantedCloud(file: file)
        engine.fullMediaFetchForTesting = { _, manifest in cloud.fetch(manifest) }
        return (store, engine, cloud)
    }

    /// This iPhone's own record, synced, whose rear still the media limit freed (its label and thumbnail kept): the
    /// download asks only for the rear still its upload named, and no still joins it under a camera it never used.
    func testADownloadIntoThisPhonesRecordAsksOnlyForItsOwnCamera() async throws {
        let (store, engine, cloud) = try engineWithPlantedCloud()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let own = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                        thumbnailData: Data([0x01]), primaryCamera: "rear", cloudSyncState: .synced)
        store.add(own)
        let result = await engine.downloadFullEvidence(for: own.id)
        XCTAssertEqual(cloud.asked, [["rear"]], "only the name its own upload gave the rear still")
        let held = try XCTUnwrap(store.events.first { $0.id == own.id })
        XCTAssertTrue(result.landed)
        XCTAssertNotNil(held.mediaFilename, "its rear still is back")
        XCTAssertEqual(held.primaryCamera, "rear")
        XCTAssertNil(held.secondaryMediaFilename, "no still under a camera this record never used")
        XCTAssertNil(held.secondaryCamera)
    }

    /// A Both capture whose front failed holds only its rear, in the second place: the download asks for the rear
    /// alone, and the empty first place takes nothing.
    func testABothCaptureWhoseFrontFailedAsksOnlyForItsRear() async throws {
        let (store, engine, cloud) = try engineWithPlantedCloud()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let own = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                        secondaryCamera: "rear", cloudSyncState: .synced)
        store.add(own)
        _ = await engine.downloadFullEvidence(for: own.id)
        XCTAssertEqual(cloud.asked, [["rear"]])
        let held = try XCTUnwrap(store.events.first { $0.id == own.id })
        XCTAssertNotNil(held.secondaryMediaFilename, "its rear still is back in its place")
        XCTAssertNil(held.mediaFilename, "the front never captured stays empty")
        XCTAssertNil(held.primaryCamera)
    }

    /// A record of this iPhone's that names no camera stored no capture (every capture this app has stored since its
    /// first build names its camera), so none went up: the download asks for no name, checks every candidate, and
    /// takes nothing. (The red asked for the two old slot names; changed with the fix, step 32's ledger entry says why.)
    func testARecordThatNamesNoCameraAsksForNothing() async throws {
        let (store, engine, cloud) = try engineWithPlantedCloud()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let own = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                        cloudSyncState: .synced)
        store.add(own)
        let result = await engine.downloadFullEvidence(for: own.id)
        XCTAssertEqual(cloud.asked, [[]], "no name")
        XCTAssertEqual(CloudExfiltrator.fullMediaRecordNames(for: own.id, manifest: []), [], "so no record to fetch")
        XCTAssertEqual(result, MonitoringEngine.EvidenceDownload(landed: false, complete: true), "every candidate checked")
        let held = try XCTUnwrap(store.events.first { $0.id == own.id })
        XCTAssertNil(held.mediaFilename, "nothing joins it")
        XCTAssertNil(held.secondaryMediaFilename)
        XCTAssertNil(held.primaryCamera, "and no label from a record's name")
        XCTAssertNil(held.secondaryCamera)
    }

    /// The control: a copy from another device asks for the names its record lists, or every name without a list.
    func testACopyFromAnotherDeviceAsksForItsListOrEveryName() async throws {
        let (store, engine, cloud) = try engineWithPlantedCloud()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let listed = Event(startDate: start, endDate: start, triggeredSensors: [.motion], cloudSyncState: .synced,
                           sourceDevice: "iPhone Air", cloudRevision: 2, cloudMediaManifest: ["front"])
        let unlisted = Event(startDate: start.addingTimeInterval(-60), endDate: start, triggeredSensors: [.motion],
                             cloudSyncState: .synced, sourceDevice: "iPhone Air", cloudRevision: 2)
        store.merge([listed, unlisted])
        _ = await engine.downloadFullEvidence(for: listed.id)
        _ = await engine.downloadFullEvidence(for: unlisted.id)
        XCTAssertEqual(cloud.asked, [["front"], nil])
    }

    // MARK: - codex-13: copies saved before the limits

    /// A copy as 1.8.1 could save it, before step 32's limits: 50,000 repeated media names, 50,000 repeated tripwires,
    /// a device name of one letter and 100,000 accent marks, and a 100 KiB thumbnail.
    private static func oldCopy(id: UUID = UUID(), revision: Int = 2) -> Event {
        Event(id: id, startDate: Date(timeIntervalSince1970: 1_000_000), endDate: Date(timeIntervalSince1970: 1_000_005),
              triggeredSensors: Array(repeating: .motion, count: 50_000) + [.power],
              thumbnailData: Data(count: 100 * 1_024), cloudSyncState: .synced,
              sourceDevice: "e" + String(repeating: "\u{301}", count: 100_000), cloudRevision: revision,
              cloudMediaManifest: Array(repeating: "front", count: 50_000) + ["rear"])
    }

    /// The log as an older version left it on disk.
    private static func writeLog(_ events: [Event]) throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: root.appendingPathComponent("events.json"))
    }

    /// codex-13 on c75f223: a copy an older version saved before the limits is held to them when the log loads; this
    /// iPhone's own record loads untouched.
    func testACopySavedBeforeTheLimitsIsHeldToThemWhenTheLogLoads() throws {
        let copy = Self.oldCopy()
        let own = Event(startDate: Date(timeIntervalSince1970: 1_000_100), endDate: Date(timeIntervalSince1970: 1_000_105),
                        triggeredSensors: [.motion], thumbnailData: Data(count: 30_000), primaryCamera: "rear",
                        cloudSyncState: .synced)
        try Self.writeLog([own, copy])
        let store = EventStore()
        XCTAssertTrue(store.hasReadTheLog)
        let held = try XCTUnwrap(store.events.first { $0.id == copy.id })
        XCTAssertEqual(held.cloudMediaManifest, ["front", "rear"], "each name once")
        XCTAssertEqual(held.triggeredSensors, [.motion, .power], "each tripwire once")
        XCTAssertNil(held.thumbnailData, "a 100 KiB thumbnail is not one")
        XCTAssertEqual(held.sourceDevice, "another device", "one character of 200 KB is no name")
        XCTAssertEqual(store.events.first { $0.id == own.id }, own, "this iPhone's own record untouched")
    }

    /// A later revision without a thumbnail does not take an oversized one back from the copy it replaces.
    func testALaterRevisionDoesNotInheritAnOversizedThumbnail() {
        let old = Self.oldCopy()
        let later = Event(id: old.id, startDate: old.startDate, endDate: old.endDate, triggeredSensors: [.motion],
                          cloudSyncState: .synced, sourceDevice: "iPhone Air", cloudRevision: 3)
        XCTAssertTrue(EventStore.supersedes(incoming: later, existing: old), "the later revision replaces it")
        XCTAssertNil(EventStore.inheritingLocalEnrichment(existing: old, incoming: later).thumbnailData,
                     "an oversized thumbnail is not inherited")
        let real = Event(id: old.id, startDate: old.startDate, endDate: old.endDate, triggeredSensors: [.motion],
                         thumbnailData: Data(count: 8_000), cloudSyncState: .synced, sourceDevice: "iPhone Air",
                         cloudRevision: 2)
        XCTAssertEqual(EventStore.inheritingLocalEnrichment(existing: real, incoming: later).thumbnailData?.count, 8_000,
                       "the control: a real thumbnail is inherited")
    }

    /// The download asks for each allowed name once, whatever list a record holds.
    func testADownloadAsksForEachNameOnceWhateverTheListHolds() {
        let names = CloudExfiltrator.fullMediaRecordNames(
            for: UUID(), manifest: Array(repeating: "front", count: 50_000) + ["bogus", "rear", "front"])
        XCTAssertEqual(names.count, 4, "front and rear, in two record generations")
    }

    /// The real path: a download into a copy loaded from an older log asks iCloud for its two names, once each.
    func testADownloadIntoACopyFromAnOlderLogAsksForEachNameOnce() async throws {
        let copy = Self.oldCopy()
        try Self.writeLog([copy])
        let (store, engine, cloud) = try engineWithPlantedCloud()
        XCTAssertNotNil(store.events.first { $0.id == copy.id }, "the copy loaded")
        _ = await engine.downloadFullEvidence(for: copy.id)
        XCTAssertEqual(cloud.asked.count, 1)
        XCTAssertEqual(cloud.asked.first ?? nil, ["front", "rear"], "two names, once each")
    }

    /// codex-13 on d6908b7 (its remainder): a status copy an older version saved with its number padded (the old
    /// decoder read "clockChanged." and 100,000 zeros and "60" as one minute) loads in its canonical form, still a clock
    /// change, and the log is written back without the padding; a refetch of the canonical copy changes nothing; this
    /// iPhone's own status row loads untouched. The resume kind's number follows the same rule.
    func testAnOldStatusCopyWithAPaddedNumberLoadsInItsCanonicalForm() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let padded = Event(startDate: start, endDate: start, triggeredSensors: [], cloudSyncState: .synced,
                           stateChange: "clockChanged." + String(repeating: "0", count: 100_000) + "60",
                           sourceDevice: "iPad")
        let resumed = Event(startDate: start.addingTimeInterval(1), endDate: start.addingTimeInterval(1),
                            triggeredSensors: [], cloudSyncState: .synced, stateChange: "resumed.+252",
                            sourceDevice: "iPad")
        let own = Event(startDate: start.addingTimeInterval(2), endDate: start.addingTimeInterval(2), triggeredSensors: [],
                        cloudSyncState: .synced, stateChange: Event.clockChangeKind(seconds: -180))
        try Self.writeLog([own, padded, resumed])
        let store = EventStore()
        store.drainIOForTesting()
        let held = try XCTUnwrap(store.events.first { $0.id == padded.id })
        XCTAssertEqual(held.stateChange, "clockChanged.60", "the canonical form")
        XCTAssertTrue(held.isStateChange, "still a status entry")
        XCTAssertEqual(held.sensorSummary, "Device clock moved forward 1 min while armed", "and read as one")
        XCTAssertEqual(store.events.first { $0.id == resumed.id }?.stateChange, "resumed.252")
        XCTAssertEqual(store.events.first { $0.id == own.id }, own, "this iPhone's own row untouched")
        let log = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("events.json")
        XCTAssertLessThan(try Data(contentsOf: log).count, 20_000, "written back without the padding")

        let record = CKRecord(recordType: CloudExfiltrator.stateRecordTypeV2)
        record.encryptedValues["eventID"] = padded.id.uuidString as CKRecordValue
        record.encryptedValues["startDate"] = start as CKRecordValue
        record.encryptedValues["kind"] = "clockChanged.60" as CKRecordValue
        record.encryptedValues["deviceName"] = "iPad" as CKRecordValue
        store.merge([try XCTUnwrap(CloudExfiltrator.stateEvent(from: record), "the canonical copy decodes")])
        XCTAssertEqual(store.events.filter { $0.id == padded.id }.map(\.stateChange), ["clockChanged.60"],
                       "one row, still canonical")
    }

    /// A square of pure color noise, one pixel per point, from a fixed seed.
    private static func noiseImage(side: Int) -> UIImage {
        var rng = SeededGenerator(seed: 0x4A0B_0032)
        var bytes = (0..<(side * side * 4)).map { index in index % 4 == 3 ? UInt8(255) : UInt8.random(in: 0...255, using: &rng) }
        let image = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage()
        }
        return UIImage(cgImage: image!)
    }
}
