//
//  Item242LaunchEvidenceTests.swift
//  MalinoisTests
//
//  The second full review of 1.13 (88) at 90815cc (BACKLOG 242; the owner, 2026-11-14: "as you recommend, wording
//  approved"), round p. Written before the changes, red at that commit (against a compile-only constant).
//  - A1 and A2 (Fable's fable-1 and fable-2): since 1.10 the evidence signer, built at launch before any PIN exists,
//    writes its file in the event log's folder (an "unsupported" line on the simulator, `keyPending` on a phone), and
//    the launch read every file there but the seen and restore markers as an earlier install's evidence. So a new
//    install opened a second time before a PIN was set asked for PIN recovery ("PIN unavailable") instead of showing
//    the welcome screen, and a reinstall's finished recovery never owed the "reinstalled" entry. The signer's file now
//    counts only when it shows records, and anything the launch cannot rule out still counts. The launch's own
//    services build the folder here: no test did before (one planted the two markers by hand).
//  - B1 (gpt6-astra-3): Settings' Security footer said Guided Access stops a snoop "powering off". Its test moved to
//    Item242RoundQTests in round q, with the owner's new words for the footer.
//

import XCTest
@testable import Malinois

@MainActor
final class Item242LaunchEvidenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem242")
    }

    override func tearDown() {
        TestIsolation.tearDown()   // the reinstall flag goes with the recovery flags
        super.tearDown()
    }

    // MARK: - A1 and A2: what the launch writes before any PIN

    /// A new install's launch: its own services (`MalinoisApp.makeServices`) write their files in the event log's folder
    /// before any PIN exists, the signer's first line among them. The folder still reads as a new install's, so the
    /// launch opens on the welcome screen, not on PIN recovery (A1: the second launch before a PIN said "PIN
    /// unavailable").
    func testTheLaunchsOwnFilesBeforeAPINLeaveTheWelcomeScreen() throws {
        let (root, services) = try launch()
        withExtendedLifetime(services) {}
        let prior = KeychainService.hasPriorLocalEvidence(in: root)
        XCTAssertFalse(prior, "the launch's own files: \(names(in: root))")
        let recovery = KeychainService.recoveryKind(pinPresence: .absent, hasCompletedSetup: false,
                                                    containerHasPriorEvents: prior)
        XCTAssertNil(recovery)
        XCTAssertEqual(Welcome.launchScreen(pinUnresolved: false, disarmed: true, recovery: recovery != nil,
                                            needsPINSetup: true, pinSetupChosen: false), .welcome)
    }

    /// A reinstall that kept its PIN: the new install's launch writes the same files before the PIN is entered, and the
    /// finished recovery still owes the "reinstalled" entry (A2: the signer's file made it never owed). The engine's own
    /// call, given the folder's answer: its default asks the same of the app's real folder.
    func testAReinstallsOwnLaunchFilesStillOweTheReinstalledEntry() throws {
        let (root, services) = try launch()
        services.engine.noteRecoveryFinished(.lostSetupFlag,
                                             priorLocalEvidence: KeychainService.hasPriorLocalEvidence(in: root))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: MonitoringEngine.reinstallRecordOwedKey),
                      "the launch's own files: \(names(in: root))")
    }

    /// A1's own case: a new install opened twice before a PIN. The first launch's services write their files and are let
    /// go, as a process that ended; the second launch's, built on the same folder as a relaunch builds them, load what
    /// the first left. The second launch routes on that folder once its services exist, before its own signer runs (the
    /// first launch routes before its signer writes, so only a second launch said "PIN unavailable"); its signer then
    /// reads the file, finds its "unsupported" already said and writes nothing new. Asked at both moments, the launch's
    /// question finds a new install's folder, so the second launch opens on the welcome screen too.
    func testASecondLaunchBeforeAPINStillOpensOnTheWelcomeScreen() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let file = signatures(in: root)
        do {
            let first = launchServices()   // not tracked: let go as a process that ended
            awaitTheSignersLines(in: file)
            withExtendedLifetime(first) {}
        }
        let second = launchServices()
        TestIsolation.track(second.engine)
        XCTAssertFalse(KeychainService.hasPriorLocalEvidence(in: root), "as the second launch routes: \(names(in: root))")
        let passed = TestFlag()
        let signer = second.evidenceSigning.signer
        Task { await signer.certifyIfNeeded(records: nil); passed.value = true }
        XCTAssertTrue(pump(until: { passed.value }, timeout: 10), "the second launch's signer took its turn")
        awaitTheSignersLines(in: file)
        let prior = KeychainService.hasPriorLocalEvidence(in: root)
        XCTAssertFalse(prior, "after the second launch's signer: \(names(in: root))")
        let recovery = KeychainService.recoveryKind(pinPresence: .absent, hasCompletedSetup: false,
                                                    containerHasPriorEvents: prior)
        XCTAssertNil(recovery)
        XCTAssertEqual(Welcome.launchScreen(pinUnresolved: false, disarmed: true, recovery: recovery != nil,
                                            needsPINSetup: true, pinSetupChosen: false), .welcome)
    }

    // MARK: - The signer's file: key lines show nothing; records, and anything not ruled out, count

    /// A phone's signer writes key lines before any PIN: a key made, certified naming no records (the log was empty, or
    /// a later key's certification, which names none), or lost (App Attest dropped it); a device without App Attest says
    /// so. Written by the file's own writer, they are no earlier evidence.
    func testASignerFileWithOnlyKeyLinesIsNoEarlierEvidence() throws {
        let folder = try newFolder()
        let file = signatures(in: folder)
        let key = Data(repeating: 7, count: 32)
        XCTAssertTrue(file.append(.init(kind: .keyPending, key: key, statement: Data("statement".utf8))))
        XCTAssertTrue(file.append(.init(kind: .keyCertified, key: key, attestation: Data("attestation".utf8), existing: [])))
        XCTAssertTrue(file.append(.init(kind: .keyCertified, key: key, attestation: Data("attestation".utf8))))
        XCTAssertTrue(file.append(.init(kind: .keyLost, key: key, at: Date())))
        XCTAssertTrue(file.append(.init(kind: .unsupported, at: Date())))
        XCTAssertFalse(KeychainService.hasPriorLocalEvidence(in: folder))
    }

    /// A line that shows the folder held records counts, each alone after a key line: a signed statement, the event log's
    /// line for an absence statement, a history gap, and a first certification naming the log's records.
    func testASignerFileThatShowsRecordsIsEarlierEvidence() throws {
        let key = Data(repeating: 7, count: 32)
        let lines: [(String, EvidenceSignatureFile.Entry)] = [
            ("a signed statement", .init(kind: .signature, key: key, statement: Data("statement".utf8),
                                         assertion: Data("assertion".utf8), record: UUID())),
            ("an absence statement's line", .init(kind: .absenceLogged, records: [UUID()], at: Date())),
            ("a history gap", .init(kind: .historyMissing, records: [UUID()], keys: [key], at: Date())),
            ("a certification naming the log's records", .init(kind: .keyCertified, key: key,
                                                               attestation: Data("attestation".utf8), existing: [UUID()]))
        ]
        for (label, line) in lines {
            let folder = try newFolder()
            let file = signatures(in: folder)
            XCTAssertTrue(file.append(.init(kind: .keyPending, key: key, statement: Data("statement".utf8))), label)
            XCTAssertTrue(file.append(line), label)
            XCTAssertTrue(KeychainService.hasPriorLocalEvidence(in: folder), label)
        }
    }

    /// The other side, with the real signer's own lines: App Attest faked as the signer's own tests fake it, the signer
    /// certifies its key and signs a record the log wrote. A folder whose only file is the signer's then shows records,
    /// so a launch with no PIN asks for PIN recovery rather than opening a fresh setup over it.
    func testTheSignersOwnLinesForARecordAreEarlierEvidence() async throws {
        let folder = try newFolder()
        let media = try newFolder()
        let chain = try TestAttestationChain()
        let file = signatures(in: folder)
        let signer = EvidenceSigner(file: file, keys: FakeKeyService(chain: chain), mediaDirectory: media,
                                    app: "1.13 (88)", now: { TestApp.date(2026, 10, 31, 1, 2) })
        await signer.certifyIfNeeded(records: [])
        let start = TestApp.date(2026, 10, 31, 1, 1)
        await signer.logWritten(generation: 1, events: [Event(startDate: start, endDate: start.addingTimeInterval(5),
                                                              triggeredSensors: [.motion], motionTrace: [0.5, 1.5])])
        let kinds = (file.read() ?? []).map(\.kind)
        XCTAssertTrue(kinds.contains(.signature), "the signer signed the record: \(kinds)")
        XCTAssertEqual(names(in: folder), [EvidenceSignatureFile.name], "the signer's file alone")
        let prior = KeychainService.hasPriorLocalEvidence(in: folder)
        XCTAssertTrue(prior)
        XCTAssertEqual(KeychainService.recoveryKind(pinPresence: .absent, hasCompletedSetup: false,
                                                    containerHasPriorEvents: prior), .lostHash)
    }

    /// A line that does not decode counts, after a key line: a kind this version does not know (a later one's), or a
    /// line a kill cut short.
    func testASignerLineThatDoesNotDecodeIsEarlierEvidence() throws {
        for (label, text) in [("a kind not known", #"{"kind":"later"}"#), ("a line cut short", #"{"kind":"keyPe"#)] {
            let folder = try newFolder()
            let file = signatures(in: folder)
            XCTAssertTrue(file.append(.init(kind: .unsupported, at: Date())), label)
            let handle = try FileHandle(forWritingTo: file.url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            XCTAssertTrue(KeychainService.hasPriorLocalEvidence(in: folder), label)
        }
    }

    /// A file that cannot be read counts, as one would while a phone is locked.
    func testASignerFileThatCannotBeReadIsEarlierEvidence() throws {
        let folder = try newFolder()
        let file = signatures(in: folder)
        XCTAssertTrue(file.append(.init(kind: .unsupported, at: Date())))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path) }
        XCTAssertNil(try? Data(contentsOf: file.url), "the test's premise: the file cannot be read")
        XCTAssertTrue(KeychainService.hasPriorLocalEvidence(in: folder))
    }

    /// A file larger than the launch reads counts unread, though its one line is a key's.
    func testASignerFileLargerThanTheLaunchReadsIsEarlierEvidence() throws {
        let folder = try newFolder()
        let file = signatures(in: folder)
        let statement = Data(repeating: 1, count: EvidenceSignatureFile.launchReadLimit * 3 / 4 + 1)
        XCTAssertTrue(file.append(.init(kind: .keyPending, key: Data(repeating: 7, count: 32), statement: statement)))
        let size = try XCTUnwrap(try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(size, EvidenceSignatureFile.launchReadLimit, "the test's premise: past the limit")
        XCTAssertTrue(KeychainService.hasPriorLocalEvidence(in: folder))
    }

    /// A link where the file belongs counts, whatever it points at (here a file of key lines).
    func testASignerFileThatIsALinkIsEarlierEvidence() throws {
        let folder = try newFolder()
        let elsewhere = try newFolder()
        let target = signatures(in: elsewhere)
        XCTAssertTrue(target.append(.init(kind: .unsupported, at: Date())))
        try FileManager.default.createSymbolicLink(at: signatures(in: folder).url, withDestinationURL: target.url)
        XCTAssertTrue(KeychainService.hasPriorLocalEvidence(in: folder))
    }

    // MARK: - Helpers

    /// The launch's services, built as a new install's launch builds them, on the test's folder. Returns once the
    /// evidence signer has written its first line, and checks that the launch wrote key lines only.
    private func launch() throws -> (URL, MalinoisApp.Services) {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let services = launchServices()
        TestIsolation.track(services.engine)
        awaitTheSignersLines(in: signatures(in: root))
        return (root, services)
    }

    /// The services a launch builds, as `MalinoisApp` builds them, on the test's folder.
    private func launchServices() -> MalinoisApp.Services {
        MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                 relaySend: { _ in })
    }

    /// Waits for the signer's first line in `file`, then checks that the file has key lines only.
    private func awaitTheSignersLines(in file: EvidenceSignatureFile) {
        pump(until: { !(file.read() ?? []).isEmpty }, timeout: 10)
        let kinds = (file.read() ?? []).map(\.kind)
        XCTAssertFalse(kinds.isEmpty, "the signer wrote its first line")
        let keyLines: [EvidenceSignatureFile.EntryKind] = [.unsupported, .keyPending, .keyCertified, .keyLost]
        XCTAssertTrue(kinds.allSatisfy { keyLines.contains($0) }, "the launch wrote key lines only: \(kinds)")
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    /// A folder of the test's own, inside its store folder (removed with it).
    private func newFolder() throws -> URL {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let folder = root.appendingPathComponent("case-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func signatures(in folder: URL) -> EvidenceSignatureFile {
        EvidenceSignatureFile(url: folder.appendingPathComponent(EvidenceSignatureFile.name))
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}
