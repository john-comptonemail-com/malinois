import XCTest
@testable import Malinois

/// iOS 18.0 traps inside JSONDecoder for some malformed keys instead of throwing. These inputs must be
/// rejected without rewriting them, while valid data and the storage readers' existing recovery rules survive.
@MainActor
final class StoredJSONTests: XCTestCase {
    private struct Record: Codable, Equatable { let value: String }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisStoredJSON")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    func testRawControlBytesInKeysAndValuesAreRejected() {
        for byte in UInt8(0)..<32 {
            for prefix in ["{\"", "{\"value\":\""] {
                let suffix = prefix == "{\"" ? "\":0}" : "\"}"
                let data = Data(prefix.utf8) + Data([byte]) + Data(suffix.utf8)
                XCTAssertThrowsError(try StoredJSON.decode(Record.self, from: data), "byte \(byte)")
            }
        }
    }

    func testMalformedUTF8AndEscapesAreRejected() {
        let encodings: [[UInt8]] = [[0xFF], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]]
        for bytes in encodings {
            let data = Data("{\"".utf8) + Data(bytes) + Data("\":0}".utf8)
            XCTAssertThrowsError(try StoredJSON.decode(Record.self, from: data))
        }
        let keys = [#"\q"#, #"\uD800"#, #"\uDC00"#, #"\uD800\u0041"#, #"\uZZZZ"#, #"\u123"#]
        for key in keys {
            XCTAssertThrowsError(try StoredJSON.decode(Record.self, from: Data("{\"\(key)\":0}".utf8)), key)
        }
        let escapedControl = Data("{\"\\".utf8) + Data([0x13]) + Data("\":0}".utf8)
        XCTAssertThrowsError(try StoredJSON.decode(Record.self, from: escapedControl))
    }

    func testValidEscapesUnicodeAndUnknownHugeNumbersKeepTheirMeaning() throws {
        let value = "quote \" slash \\ control \u{13} 日本語 🐕"
        let record = Record(value: value)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try StoredJSON.decode(Record.self, from: data), record)
        for length in 0...8 {
            for suffix in ["", "\"", "tail", "\u{7F}", "\u{2028}\u{2029}"] {
                let escaped = Record(value: String(repeating: "\\", count: length) + suffix)
                XCTAssertEqual(try StoredJSON.decode(Record.self, from: JSONEncoder().encode(escaped)), escaped)
            }
        }
        let future = Data(#"{"ignored":1e400,"value":"kept","未知":"\uD83D\uDC15"}"#.utf8)
        XCTAssertEqual(try StoredJSON.decode(Record.self, from: future), Record(value: "kept"))
        XCTAssertEqual(try StoredJSON.decode(UInt64.self, from: Data("18446744073709551615".utf8)), UInt64.max)
        XCTAssertEqual(try StoredJSON.decode(String.self, from: Data(#""\u0013""#.utf8)), "\u{13}")
    }

    func testSlicesAndBackslashParityDoNotChangeDecoding() throws {
        let valid = Data(#"xxxx{"value":"a\\\"b"}"#.utf8).dropFirst(4)
        XCTAssertEqual(try StoredJSON.decode(Record.self, from: valid), Record(value: "a\\\"b"))
        let invalid = (Data("xxxx{\"".utf8) + Data([0x13]) + Data("\":0}".utf8)).dropFirst(4)
        XCTAssertThrowsError(try StoredJSON.decode(Record.self, from: invalid))
        for input in [#"{"value":"truncated"#, "{\"value\":\"truncated\\"] {
            XCTAssertThrowsError(try StoredJSON.decode(Record.self, from: Data(input.utf8)))
        }
    }

    func testJournalReaderKeepsGoodLinesAroundMalformedKeys() throws {
        let first = event(), last = event()
        let data = try line(first) + damagedObject(line(event())) + Data([0x0A]) + line(last)
        XCTAssertEqual(EventStore.journaledEvents(in: data), [first, last])
    }

    func testLaunchRecoversHealthyJournalRowsAndCanLaunchAgain() throws {
        let root = try folder()
        let first = event(), last = event()
        let journal = root.appendingPathComponent("events.journal")
        try (line(first) + damagedObject(line(event())) + Data([0x0A]) + line(last)).write(to: journal)
        let store = EventStore()
        XCTAssertEqual(Set(store.events), Set([first, last]))
        store.drainIOForTesting()
        let reopened = EventStore()
        XCTAssertEqual(Set(reopened.events), Set([first, last]))
        reopened.drainIOForTesting()
    }

    func testCheckpointDropsMalformedLineAndPreservesUnpersistedRow() async throws {
        let root = try folder()
        let store = EventStore()
        let persisted = event(), later = event()
        store.add(persisted)
        store.drainIOForTesting()
        let journal = root.appendingPathComponent("events.journal")
        // Before the scheduled checkpoint runs, model a surviving newer append plus damaged bytes.
        try (line(persisted) + damagedObject(line(event())) + Data([0x0A]) + line(later)).write(to: journal)
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(3))
        var data = Data()
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            data = (try? Data(contentsOf: journal)) ?? Data()
            if EventStore.journaledEvents(in: data) == [later] { break }
        } while clock.now < deadline
        XCTAssertEqual(EventStore.journaledEvents(in: data), [later])
        let reopened = EventStore()
        XCTAssertEqual(Set(reopened.events.map(\.id)), Set([persisted.id, later.id]))
        reopened.drainIOForTesting()
    }

    func testMalformedMainLogIsPreservedAndHealthyJournalStillRecovers() throws {
        let root = try folder()
        let bytes = try Data([0x5B]) + damagedObject(JSONEncoder().encode(event())) + Data([0x5D])
        try bytes.write(to: root.appendingPathComponent("events.json"))
        let healthy = event()
        try line(healthy).write(to: root.appendingPathComponent("events.journal"))
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let photo = media.appendingPathComponent("preserved.jpg")
        try Data([1, 2, 3]).write(to: photo)
        let store = EventStore()
        XCTAssertTrue(store.logWasQuarantined)
        XCTAssertEqual(store.events, [healthy])
        store.drainIOForTesting()
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path)
            .first { $0.hasPrefix("events.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(backup)), bytes)
        XCTAssertEqual(try Data(contentsOf: photo), Data([1, 2, 3]))
    }

    func testDamagedOwedReportsArePreservedWithoutInventingAReport() throws {
        let root = try folder()
        let bytes = Data([0x5B]) + damagedObject(Data("{}".utf8)) + Data([0x5D])
        try bytes.write(to: root.appendingPathComponent(EventStore.reportsOwedFileName))
        let store = EventStore()
        store.drainIOForTesting()
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path)
            .first { $0.hasPrefix("reports-owed.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(backup)), bytes)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testDamagedRestoreAndSeenMarkersDoNotHideExistingEvents() throws {
        let root = try folder(), healthy = event()
        try JSONEncoder().encode([healthy]).write(to: root.appendingPathComponent("events.json"))
        let bytes = damagedObject(Data("{\"since\":0}".utf8))
        try bytes.write(to: root.appendingPathComponent(EventStore.restoreOwedFileName))
        try bytes.write(to: root.appendingPathComponent(EventStore.seenFileName))
        let store = EventStore()
        XCTAssertEqual(store.events, [healthy])
        XCTAssertEqual(store.seenIDs, Set([healthy.id]))
        XCTAssertNil(store.restoreOwedSince)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(EventStore.restoreOwedFileName)), bytes)
        store.drainIOForTesting()
    }

    func testMalformedAttachmentIntentCannotAttachOrDeleteMedia() throws {
        let root = try folder(), healthy = event()
        try JSONEncoder().encode([healthy]).write(to: root.appendingPathComponent("events.json"))
        let intents = root.appendingPathComponent("MediaAttachments"), media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: intents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let name = UUID().uuidString
        let intent = intents.appendingPathComponent(name + ".json")
        let bytes = damagedObject(Data("{}".utf8))
        try bytes.write(to: intent)
        let photo = media.appendingPathComponent(name + ".jpg")
        try Data([1, 2, 3]).write(to: photo)
        let store = EventStore()
        store.drainIOForTesting()
        XCTAssertEqual(store.events, [healthy])
        XCTAssertEqual(try Data(contentsOf: intent), bytes)
        XCTAssertEqual(try Data(contentsOf: photo), Data([1, 2, 3]))
    }

    private func folder() throws -> URL {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func event() -> Event {
        Event(startDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
              endDate: Date(timeIntervalSinceReferenceDate: 800_000_001), triggeredSensors: [.motion])
    }

    private func line(_ event: Event) throws -> Data { try XCTUnwrap(EventStore.journalLine(for: event)) }

    private func damagedObject(_ data: Data) -> Data {
        Data("{\"bad".utf8) + Data([0x13]) + Data("\":0,".utf8) + data.dropFirst()
    }
}

/// Raw control bytes in object keys used to trap inside Foundation on iOS 18. These cases enter through
/// the persisted-data readers and pin each reader's existing recovery rule, beyond the JSON parser itself.
@MainActor
final class StoredJSONPathTests: XCTestCase {
    nonisolated private static let settingsKey = "com.malinois.settings"
    nonisolated private static let protectionKey = "com.malinois.protection.recorded"
    nonisolated private static let beatsKey = "com.malinois.beats.sessions"

    // XCTest calls synchronous setup/teardown on the main thread without actor isolation.
    nonisolated(unsafe) private var savedSettings: [String: Any] = [:]
    nonisolated(unsafe) private var savedCanary: URL?

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisStoredJSON")
        let defaults = UserDefaults.standard
        savedSettings = defaults.dictionaryRepresentation().filter {
            $0.key == Self.settingsKey || $0.key.hasPrefix(Self.settingsKey + ".corrupt-")
        }
        savedSettings.keys.forEach { defaults.removeObject(forKey: $0) }
        savedCanary = AppSettings.canaryURLOverrideForTesting
        AppSettings.canaryURLOverrideForTesting = EventStore.rootOverrideForTesting?.appendingPathComponent("canary")
    }

    override func tearDown() {
        TestIsolation.tearDown()   // release engines and their settings' pending autosaves before restoring preferences
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys.filter {
            $0 == Self.settingsKey || $0.hasPrefix(Self.settingsKey + ".corrupt-")
        }.forEach { defaults.removeObject(forKey: $0) }
        for (key, value) in savedSettings { defaults.set(value, forKey: key) }
        AppSettings.canaryURLOverrideForTesting = savedCanary
        super.tearDown()
    }

    /// Add one malformed, otherwise unused key to an encoded object (or the first object in an array).
    /// All original fields remain intact: a permissive parser that ignored this key would accept the fixture.
    private func damagedKey(in encoded: Data) throws -> Data {
        var bytes = encoded
        let object = try XCTUnwrap(bytes.firstIndex(of: 0x7B))
        let key = Data("\"damaged".utf8) + Data([0x13]) + Data("\":0,".utf8)
        bytes.insert(contentsOf: key, at: object + 1)
        return bytes
    }

    func testDamagedCloudGrantStaysUnavailableAndIsNotOverwritten() async throws {
        let file = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("grant/state.json")
        let original = CloudEnrollment(file: file, authenticate: { _ in true })
        let enrolled = await original.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let damaged = try damagedKey(in: Data(contentsOf: file))
        try damaged.write(to: file, options: .atomic)

        var prompts = 0
        let restored = CloudEnrollment(file: file, authenticate: { _ in prompts += 1; return true })
        XCTAssertFalse(restored.verified)
        XCTAssertFalse(restored.newEventsBindToVerifiedAccount)
        XCTAssertNil(restored.authorize(account: "account-a"), "unreadable grants issue no upload lease")
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        restored.registerLocalEvent(event)
        XCTAssertEqual(restored.uploadHoldReason(for: event), .unavailable)
        let retried = await restored.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertFalse(retried, "verification must not replace an unreadable existing grant")
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(try Data(contentsOf: file), damaged, "the original grant remains available for recovery")
    }

    func testDamagedSettingsArePreservedResetAndStillOweTheirResetRecord() throws {
        let defaults = UserDefaults.standard
        let damaged = try damagedKey(in: JSONEncoder().encode(AppSettings()))
        defaults.set(damaged, forKey: Self.settingsKey)

        let loaded = AppSettings.load()
        XCTAssertTrue(loaded.wasResetAtLoad, "the owner is told that settings were reset")
        XCTAssertFalse(loaded.cloudBackup, "unreadable privacy choices cannot enable uploading")
        XCTAssertEqual(loaded.cloudRetention, .forever, "recovery cannot silently enable cloud deletion")
        XCTAssertEqual(loaded.gracePeriodSeconds, AppSettings().gracePeriodSeconds)
        let resetID = try XCTUnwrap(defaults.string(forKey: AppSettings.resetPendingKey))
        XCTAssertNotNil(UUID(uuidString: resetID))
        let stashes = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(Self.settingsKey + ".corrupt-")
        }
        XCTAssertTrue(stashes.contains { defaults.data(forKey: $0) == damaged }, "preserve the original bytes")
        let replacement = try XCTUnwrap(defaults.data(forKey: Self.settingsKey))
        XCTAssertNotEqual(replacement, damaged)
        XCTAssertNoThrow(try JSONDecoder().decode(AppSettings.self, from: replacement))

        let relaunched = AppSettings.load()
        XCTAssertTrue(relaunched.wasResetAtLoad, "a relaunch cannot forget the reset before its audit record is written")
        XCTAssertFalse(relaunched.cloudBackup)
        XCTAssertEqual(relaunched.cloudRetention, .forever)
        XCTAssertEqual(defaults.string(forKey: AppSettings.resetPendingKey), resetID)
        XCTAssertTrue(stashes.contains { defaults.data(forKey: $0) == damaged })
    }

    func testDamagedWatchMemoryKeepsLegacyDedupAndAllowsANewAlert() async throws {
        let suite = "MalinoisStoredJSONWatch-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let old = WatchAlertMessage(kind: .tamper, eventID: UUID(), at: now)
        let fresh = WatchAlertMessage(kind: .tamper, eventID: UUID(), at: now)
        let memory = WatchRelayMemory(shown: [old.notificationIdentifier], summed: [], summary: nil)
        let damaged = try damagedKey(in: JSONEncoder().encode(memory))
        defaults.set(damaged, forKey: WatchRelayInbox.memoryKey)
        defaults.set([old.notificationIdentifier], forKey: WatchRelayInbox.shownRelayIDsKey)
        var posted: [String] = []
        let inbox = WatchRelayInbox(defaults: defaults, now: { now }, post: { posted.append($0.identifier) })

        XCTAssertEqual(defaults.data(forKey: WatchRelayInbox.memoryKey), damaged, "reading alone does not erase memory")
        let duplicatePosted = await inbox.receive(old)
        await inbox.repeatTidy?.value
        XCTAssertFalse(duplicatePosted, "the surviving legacy list still suppresses a duplicate")
        XCTAssertTrue(posted.isEmpty)
        let freshPosted = await inbox.receive(fresh)
        XCTAssertTrue(freshPosted)
        XCTAssertEqual(posted, [fresh.notificationIdentifier])
        let kept = try XCTUnwrap(WatchRelayMemory.read(defaults.data(forKey: WatchRelayInbox.memoryKey)))
        XCTAssertTrue(kept.shown.contains(old.notificationIdentifier))
        XCTAssertTrue(kept.shown.contains(fresh.notificationIdentifier))
    }

    func testDamagedHeartbeatRegistryUsesItsEmptyFallbackWithoutChangingStoredBytes() throws {
        let session = BeatSession(id: UUID(), start: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let damaged = try damagedKey(in: JSONEncoder().encode([session]))
        let defaults = UserDefaults.standard
        defaults.set(damaged, forKey: Self.beatsKey)
        XCTAssertEqual(BeatSessionRegistry.read(), [], "unreadable registry cannot invent sessions to trim")
        XCTAssertEqual(defaults.data(forKey: Self.beatsKey), damaged, "a read is not a rewrite")
        XCTAssertTrue(BeatSessionRegistry.save([session]))
        XCTAssertEqual(BeatSessionRegistry.read(), [session], "a later valid registry can be read normally")
    }

    func testDamagedProtectionBaselineAtLaunchIsAdoptedWithoutInventingAnEdit() throws {
        let settings = AppSettings()
        let damaged = try damagedKey(in: JSONEncoder().encode(ProtectionSettings(settings)))
        UserDefaults.standard.set(damaged, forKey: Self.protectionKey)
        let (engine, store) = makeEngine(settings)
        XCTAssertEqual(settingsRecords(in: store), [], "an unreadable old baseline is not a user edit")
        XCTAssertEqual(try storedProtection(), ProtectionSettings(settings))
        settings.enabledSensors.remove(.camera)
        engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(in: store), ["settingOff.camera"], "the next real edit is still recorded")
    }

    func testDamagedProtectionBaselineAtComparisonIsAdoptedAndTheNextEditIsRecorded() throws {
        let settings = AppSettings()
        let (engine, store) = makeEngine(settings)
        let damaged = try damagedKey(in: JSONEncoder().encode(ProtectionSettings(settings)))
        UserDefaults.standard.set(damaged, forKey: Self.protectionKey)
        engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(in: store), [], "no history can be inferred from damaged baseline bytes")
        XCTAssertEqual(try storedProtection(), ProtectionSettings(settings))
        settings.enabledSensors.remove(.camera)
        engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(in: store), ["settingOff.camera"])
    }

    private func makeEngine(_ settings: AppSettings) -> (MonitoringEngine, EventStore) {
        let store = EventStore()
        let cloud = CloudExfiltrator()
        cloud.accountIdentityForTesting = { nil }
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .free),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, store)
    }

    private func settingsRecords(in store: EventStore) -> [String] {
        store.events.compactMap(\.stateChange).filter { $0.hasPrefix("setting") }
    }

    private func storedProtection() throws -> ProtectionSettings {
        let bytes = try XCTUnwrap(UserDefaults.standard.data(forKey: Self.protectionKey))
        return try JSONDecoder().decode(ProtectionSettings.self, from: bytes)
    }
}
