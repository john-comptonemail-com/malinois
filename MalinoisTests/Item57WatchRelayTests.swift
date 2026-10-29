//
//  Item57WatchRelayTests.swift
//  MalinoisTests
//
//  BACKLOG 57, build 60 (owner, 2026-10-12: "A, go ahead"; ADR 0043). TestFlight 1.6 (59) showed
//  iCloud never sends a watch the alerts caused by its own paired iPhone (the iPad mini's reached
//  it in about 2 s), so the armed iPhone also sends its own alerts straight to its watch over
//  Bluetooth or shared Wi-Fi. The relay watches the log: each new first-hand incident sends the
//  tamper alert and each new first-hand disarm the disarm alert, on the same terms as the iCloud
//  alerts (Cross-device alerts on, Pro active), with the iCloud alerts' fixed texts. Written before
//  the change, red at that commit (against compile-only stubs).
//

import XCTest
@testable import Malinois

@MainActor
final class Item57WatchRelayTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem57Relay")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func event(stateChange: String? = nil, from device: String? = nil,
                       sensors: [SensorType] = [.motion]) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: stateChange == nil ? sensors : [],
              stateChange: stateChange, sourceDevice: device)
    }

    // MARK: - Which events send which alert

    /// A first-hand incident sends the tamper alert and a first-hand disarm the disarm alert;
    /// another device's events and silent status entries send nothing.
    func testEachNewFirstHandIncidentAndDisarmSendsItsAlert() {
        let trip = event()
        let disarm = event(stateChange: "disarmed")
        let alerts = WatchAlertRelay.alerts(for: [trip, disarm, event(stateChange: "armed"),
                                                  event(stateChange: "thermalSerious"), event(from: "iPad mini"),
                                                  event(stateChange: "disarmed", from: "iPad mini")],
                                            alertsOn: true, proActive: true)
        XCTAssertEqual(alerts.map(\.kind), [.tamper, .disarm])
        XCTAssertEqual(alerts.map(\.eventID), [trip.id, disarm.id])
    }

    /// Only on the iCloud alerts' terms: Cross-device alerts on, Pro active.
    func testNothingIsSentWithCrossDeviceAlertsOffOrWithoutPro() {
        XCTAssertTrue(WatchAlertRelay.alerts(for: [event()], alertsOn: false, proActive: true).isEmpty)
        XCTAssertTrue(WatchAlertRelay.alerts(for: [event()], alertsOn: true, proActive: false).isEmpty)
    }

    /// The relay watches the log: what was there when it started is not news, a new incident is sent
    /// once, and a later update to the same event (coalescing, sync) sends nothing more.
    func testTheRelaySendsEachNewEventOnce() {
        let store = EventStore()
        store.add(event())
        let settings = AppSettings()
        settings.notifyOtherDevices = true
        var sent: [WatchAlertMessage] = []
        let relay = WatchAlertRelay(store: store, settings: settings,
                                    entitlements: ProEntitlements(resolvedAs: .trial), send: { sent.append($0) })
        relay.start()
        XCTAssertTrue(sent.isEmpty, "the log at start is not news")
        let trip = event()
        store.add(trip)
        XCTAssertEqual(sent.map(\.eventID), [trip.id])
        store.add(event(from: "iPad mini"))
        XCTAssertEqual(sent.count, 1, "another device's event comes through iCloud instead")
        store.add(event(stateChange: "disarmed"))
        XCTAssertEqual(sent.map(\.kind), [.tamper, .disarm])
    }

    // MARK: - Item 152's lead 19 (1.8.2's step 11): the launch window before the first Pro check

    private func makeRelay(_ entitlements: ProEntitlements, store: EventStore,
                           into sent: @escaping (WatchAlertMessage) -> Void) -> WatchAlertRelay {
        let settings = AppSettings()
        settings.notifyOtherDevices = true
        let relay = WatchAlertRelay(store: store, settings: settings, entitlements: entitlements, send: sent)
        relay.start()
        return relay
    }

    /// An incident logged before the first Pro check resolves (a cold launch's interruption record) is held, not
    /// dropped, and sent once the check says Pro is on; later incidents go as before. Red at the step's red commit: it
    /// was marked handled while Pro still read as off, and never sent.
    func testAnIncidentLoggedBeforeTheProCheckIsSentOnceItResolves() {
        let store = EventStore()
        let entitlements = ProEntitlements.unresolvedForTesting()
        var sent: [WatchAlertMessage] = []
        let relay = makeRelay(entitlements, store: store) { sent.append($0) }
        let record = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], interrupted: true)
        store.add(record)
        XCTAssertTrue(sent.isEmpty, "not before the check says whether Pro is on")
        entitlements.resolveForTesting(as: .earlyAccess)
        XCTAssertEqual(sent.map(\.eventID), [record.id], "sent once it resolves")
        let trip = event()
        store.add(trip)
        XCTAssertEqual(sent.map(\.eventID), [record.id, trip.id], "and the relay goes on as before")
        withExtendedLifetime(relay) {}
    }

    /// What waits for the first Pro check is bounded, as the watch link's own outbox is: at most 20, the newest kept
    /// (Codex's note on step 11).
    func testAtMostTwentyIncidentsWaitForTheProCheck() {
        let store = EventStore()
        let entitlements = ProEntitlements.unresolvedForTesting()
        var sent: [WatchAlertMessage] = []
        let relay = makeRelay(entitlements, store: store) { sent.append($0) }
        let incidents = (0..<25).map { _ in event() }
        for incident in incidents { store.add(incident) }
        entitlements.resolveForTesting(as: .earlyAccess)
        XCTAssertEqual(sent.map(\.eventID), incidents.suffix(20).map(\.id))
        withExtendedLifetime(relay) {}
    }

    /// A check that resolves without Pro sends nothing for the held incident, as for any incident without Pro.
    func testAnIncidentHeldForAProCheckThatFindsNoProIsNotSent() {
        let store = EventStore()
        let entitlements = ProEntitlements.unresolvedForTesting()
        var sent: [WatchAlertMessage] = []
        let relay = makeRelay(entitlements, store: store) { sent.append($0) }
        store.add(event())
        entitlements.resolveForTesting(as: .free)
        XCTAssertTrue(sent.isEmpty)
        withExtendedLifetime(relay) {}
    }

    // MARK: - The message

    /// The watch shows the iCloud alerts' own fixed texts: no device, sensor or evidence detail.
    func testTheMessageCarriesTheICloudAlertsFixedTexts() {
        let tamper = WatchAlertMessage(kind: .tamper, eventID: UUID(), at: Date())
        let disarm = WatchAlertMessage(kind: .disarm, eventID: UUID(), at: Date())
        XCTAssertEqual(tamper.title, "Malinois")
        XCTAssertEqual(tamper.body, CloudExfiltrator.makeTamperSubscription().notificationInfo?.alertBody)
        XCTAssertEqual(disarm.body, CloudExfiltrator.makeDisarmSubscription().notificationInfo?.alertBody)
        XCTAssertNotEqual(tamper.notificationIdentifier, disarm.notificationIdentifier, "one alert per event")
    }

    /// The message survives the trip to the watch, and anything else is ignored.
    func testTheMessageRoundTripsAndRejectsAnythingElse() {
        let message = WatchAlertMessage(kind: .disarm, eventID: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(WatchAlertMessage(userInfo: message.userInfo), message)
        XCTAssertNil(WatchAlertMessage(userInfo: [:]))
        XCTAssertNil(WatchAlertMessage(userInfo: ["kind": "tamper", "id": "not a UUID", "at": 1.0]))
    }

    /// The app starts the relay with its services, before the engine, so a record the engine writes
    /// at launch is relayed too: here the interruption record of an armed session the app never
    /// ended. Run through the launch's own construction; read from the app's source, this passed
    /// with the relay built but never started (the test-suite audit's probe W340; P4).
    func testTheAppStartsTheRelayBeforeTheEngine() throws {
        UserDefaults.standard.set(0.5, forKey: "com.malinois.armedSession.brightness")   // armed, never disarmed
        var sent: [WatchAlertMessage] = []
        let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                relaySend: { sent.append($0) })
        TestIsolation.track(services.engine)
        let interruption = try XCTUnwrap(services.eventStore.events.first { $0.interrupted == true },
                                         "the engine records the interruption at launch")
        XCTAssertTrue(sent.contains { $0.eventID == interruption.id && $0.kind == .tamper },
                      "and the relay, already listening, sends it to the watch")
    }
}
