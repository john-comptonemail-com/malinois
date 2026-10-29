//
//  Item141SirenRouteTests.swift
//  MalinoisTests
//
//  Where the siren plays. Fable's fable-2 on 1.8 (75) (BACKLOG 141): the siren played through the iPhone's current
//  audio output, so with headphones or a Bluetooth device connected it was not heard in the room; 1.8 (76) warned at
//  the countdown (ADR 0053). The owner's check A on 1.8.1 (2026-10-27) showed headphones connected during a watch take
//  it too, so since 1.8.2 (BACKLOG 163's step 26, item 155's A12; ADR 0062) the siren plays from this iPhone's speaker
//  in Siren mode whatever is connected, an alarm playing elsewhere is logged, and the countdown's warning is gone.
//  Written before the change, red at that commit (against compile-only stand-ins).
//

import AVFoundation
import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item141SirenRouteTests: XCTestCase {
    private static let airPods = SirenOutput(port: .bluetoothA2DP, name: "Owner's AirPods Pro")
    private static let speaker = SirenOutput(port: .builtInSpeaker, name: "Speaker")

    private struct Rig {
        let engine: MonitoringEngine
        let settings: AppSettings
        let entitlements: ProEntitlements
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem141Siren")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - 1.8.2's step 26 (item 155's A12; ADR 0062): the siren on this iPhone's speaker in Siren mode

    private static let headphones = SirenOutput(port: .headphones, name: "Headphones")
    private static let elsewhereWords = "The siren played through Owner's AirPods Pro, not this iPhone's speaker"

    /// Siren mode's setting is the recording one, the only one iOS lets an app pin to the speaker: `defaultToSpeaker`,
    /// and none of the options that would let Bluetooth headphones (HFP or A2DP) or AirPlay take the sound; other apps'
    /// sound still ducks. The other alarms keep the playback setting.
    func testSirenModesSettingIsTheSpeakerOne() {
        let speaker = SirenPlayer.audioSetting(onSpeaker: true)
        XCTAssertEqual(speaker.category, .playAndRecord)
        XCTAssertTrue(speaker.options.contains(.defaultToSpeaker))
        XCTAssertTrue(speaker.options.contains(.duckOthers))
        for away: AVAudioSession.CategoryOptions in [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay] {
            XCTAssertFalse(speaker.options.contains(away), "option \(away.rawValue)")
        }
        let route = SirenPlayer.audioSetting(onSpeaker: false)
        XCTAssertEqual(route.category, .playback)
        XCTAssertEqual(route.options, [.duckOthers])
    }

    /// The real path: a Siren-mode trip sounds the siren with the speaker setting and asks iOS for the speaker, which
    /// covers wired headphones too. Red at the step's red commit: it played with the playback setting, which goes
    /// wherever the sound goes (the owner's check A on 1.8.1: into AirPods connected during a watch).
    func testASirenModeTripPlaysOnTheSpeaker() {
        let rig = makeRig(mode: .siren, grace: 0)
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.siren.isPlaying }, timeout: 5), "the siren sounds")
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playAndRecord, "the speaker setting")
        XCTAssertTrue(session.categoryOptions.contains(.defaultToSpeaker))
        XCTAssertGreaterThanOrEqual(rig.engine.siren.speakerOverridesForTesting, 1, "the speaker asked for")
        XCTAssertEqual(session.currentRoute.outputs.map(\.portType), [.builtInSpeaker], "this iPhone's speaker")
        rig.engine.disarm()
    }

    /// Siren mode's escalations (a sensor flood here) go loud at once, on the speaker too.
    func testASirenModeEscalationPlaysOnTheSpeaker() {
        let rig = makeRig(mode: .siren, grace: 0)
        arm(rig)
        rig.engine.escalate(.flood)
        XCTAssertTrue(pump(until: { rig.engine.siren.isPlaying }, timeout: 5), "the siren sounds")
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord, "the speaker setting")
        rig.engine.disarm()
    }

    /// Alert and Stealth keep their suspected-attack alarm as it was (the owner's ruling, 2026-10-28): the playback
    /// setting, which plays wherever the sound goes. A control: it passed before the change too.
    func testTheAttackAlarmInAlertAndStealthKeepsThePlaybackSetting() {
        for mode in [ResponseMode.alert, .stealth] {
            let rig = makeRig(mode: mode, grace: 0)
            arm(rig)
            rig.engine.escalate(.blackout)
            XCTAssertTrue(pump(until: { rig.engine.siren.isPlaying }, timeout: 5), "\(mode): the alarm sounds")
            XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback, "\(mode)")
            XCTAssertEqual(rig.engine.siren.speakerOverridesForTesting, 0, "\(mode)")
            rig.engine.disarm()
        }
    }

    /// A speaker setting iOS will not start falls back to the old one for that alarm, which still sounds; the next
    /// alarm tries the speaker again.
    func testASpeakerSettingThatFailsFallsBackAndTheNextAlarmTriesAgain() {
        let siren = SirenPlayer()
        siren.speakerSettingFailuresForTesting = 100
        siren.start(onSpeaker: true)
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm still sounds")
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback, "with the old setting")
        siren.stop()
        siren.speakerSettingFailuresForTesting = 0
        siren.start(onSpeaker: true)
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the next alarm sounds")
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord, "on the speaker setting again")
        siren.stop()
    }

    /// The Sound tripwire leaves the session in the measurement mode, which Apple documents as lowering the playback
    /// level; both of the siren's settings name the default mode, so it never plays in that one.
    func testTheSirenNeverPlaysInTheSoundTripwiresMeasurementMode() throws {
        let session = AVAudioSession.sharedInstance()
        for onSpeaker in [false, true] {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            let siren = SirenPlayer()
            siren.start(onSpeaker: onSpeaker)
            XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "onSpeaker \(onSpeaker): the alarm sounds")
            XCTAssertEqual(session.mode, .default, "onSpeaker \(onSpeaker)")
            siren.stop()
        }
    }

    /// A device connected while the alarm sounds on the speaker setting (wired headphones, a USB device, a car) would
    /// take the sound, since iOS drops the speaker override at every change of route: the siren asks for the speaker
    /// again. Not while the sound is on the speaker, not while a call holds the audio, and not once the alarm stops.
    func testARouteChangeWhileSoundingPutsTheSpeakerBack() {
        let siren = SirenPlayer()
        siren.start(onSpeaker: true)
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm sounds")
        settle(0.5)   // iOS's own notices of the start's route changes
        let asked = siren.speakerOverridesForTesting
        siren.outputsForTesting = [Self.speaker]
        postRouteChange()
        settle(0.3)
        XCTAssertEqual(siren.speakerOverridesForTesting, asked, "on the speaker already")
        siren.outputsForTesting = [Self.headphones]
        postRouteChange()
        XCTAssertTrue(pump(until: { siren.speakerOverridesForTesting > asked }, timeout: 2), "the speaker asked for again")
        let after = siren.speakerOverridesForTesting
        siren.silenceForTesting()   // what a call does to the player: stopped, the alarm still owed
        postRouteChange()
        settle(0.3)
        XCTAssertEqual(siren.speakerOverridesForTesting, after, "not while a call holds the audio")
        siren.stop()
        postRouteChange()
        settle(0.3)
        XCTAssertEqual(siren.speakerOverridesForTesting, after, "not once the alarm stops")
    }

    /// The playback setting is left to go wherever the sound goes: no speaker asked for at a route change. A control.
    func testARouteChangeLeavesThePlaybackSettingAlone() {
        let siren = SirenPlayer()
        siren.start()
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm sounds")
        siren.outputsForTesting = [Self.headphones]
        postRouteChange()
        settle(0.3)
        XCTAssertEqual(siren.speakerOverridesForTesting, 0)
        siren.stop()
    }

    /// An alarm playing elsewhere is reported once from its start to its stop, whatever restarts it (a call's end
    /// here); the next alarm is reported again. Nothing is reported for the speaker.
    func testAnAlarmPlayingElsewhereIsReportedOnceAnAlarm() {
        let siren = SirenPlayer()
        var reported: [SirenOutput] = []
        siren.onPlayingElsewhere = { reported.append($0) }
        siren.outputsForTesting = [Self.airPods]
        siren.start()
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm sounds")
        XCTAssertEqual(reported, [Self.airPods], "where it plays")
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        settle(0.5)
        XCTAssertTrue(siren.isPlaying, "restarted after the call")
        XCTAssertEqual(reported.count, 1, "once an alarm")
        siren.stop()
        siren.start()
        XCTAssertTrue(pump(until: { reported.count == 2 }, timeout: 3), "the next alarm")
        siren.stop()
        siren.outputsForTesting = [Self.speaker]
        siren.start()
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm sounds")
        XCTAssertEqual(reported.count, 2, "nothing for the speaker")
        siren.stop()
    }

    /// The real path: Alert mode's suspected-attack alarm with AirPods taking the sound logs one status entry, in the
    /// approved words (the owner, 2026-10-28: "approved"). Red at the step's red commit: nothing was logged.
    func testAnAlarmPlayingElsewhereIsLogged() {
        let rig = makeRig(mode: .alert, grace: 0)
        rig.engine.sirenOutputsForTesting = [Self.airPods]
        arm(rig)
        rig.engine.escalate(.blackout)
        XCTAssertTrue(pump(until: { rig.engine.siren.isPlaying }, timeout: 5), "the alarm sounds")
        XCTAssertTrue(pump(until: { self.entries(rig, Self.elsewhereWords) == 1 }, timeout: 3), "logged")
        settle(0.3)
        XCTAssertEqual(entries(rig, Self.elsewhereWords), 1, "once")
        rig.engine.disarm()
    }

    /// Siren mode whose speaker setting would not start plays with the old one: where it played is logged.
    func testSirenModesFallbackIsLogged() {
        let rig = makeRig(mode: .siren, grace: 0)
        rig.engine.siren.speakerSettingFailuresForTesting = 100
        rig.engine.sirenOutputsForTesting = [Self.airPods]
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.siren.isPlaying }, timeout: 5), "the siren sounds")
        XCTAssertTrue(pump(until: { self.entries(rig, Self.elsewhereWords) == 1 }, timeout: 3), "logged")
        rig.engine.disarm()
    }

    /// On the speaker setting the siren plays from the speaker by design: no entry, whatever the route read says
    /// (a control).
    func testSirenModeOnTheSpeakerLogsNothing() {
        let rig = makeRig(mode: .siren, grace: 0)
        rig.engine.sirenOutputsForTesting = [Self.airPods]
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.siren.isPlaying }, timeout: 5), "the siren sounds")
        settle(0.5)
        XCTAssertEqual(entries(rig, "The siren played through", prefix: true), 0)
        rig.engine.disarm()
    }

    /// The entry's words, with the name iOS gives the device, or "headphones or another device" for none; its icon.
    func testTheEntrysWords() throws {
        let kind = Event.sirenElsewhereKind(device: "Owner's AirPods Pro")
        XCTAssertEqual(Event.sirenElsewhereSummary(kind: kind), Self.elsewhereWords)
        XCTAssertEqual(Event.sirenElsewhereSummary(kind: Event.sirenElsewhereKind(device: " \n")),
                       "The siren played through headphones or another device, not this iPhone's speaker")
        let event = Event(id: UUID(), startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: Event.sirenElsewhereKind(device: "CarPlay"))
        XCTAssertEqual(event.sensorSummary, "The siren played through CarPlay, not this iPhone's speaker")
        XCTAssertEqual(EventRow.placeholderIcon(for: event.stateChange), "headphones")
    }

    /// The name is kept as a device label is: no whitespace at either end, no control or direction characters, at
    /// most 40 characters and 160 bytes.
    func testTheDevicesNameIsMadeSafe() {
        XCTAssertEqual(Event.sirenOutputName("  Car\u{202E}Play\n "), "CarPlay")
        XCTAssertEqual(Event.sirenOutputName(String(repeating: "a", count: 100)).count, 40)
        XCTAssertLessThanOrEqual(Event.sirenOutputName(String(repeating: "\u{1F600}", count: 100)).utf8.count, 160)
        // Seven bytes a character (an e and three accents): forty of them pass the character limit, not the bytes'.
        XCTAssertLessThanOrEqual(Event.sirenOutputName(String(repeating: "e\u{301}\u{301}\u{301}", count: 40)).utf8.count, 160)
        XCTAssertEqual(Event.sirenOutputName(String(repeating: "b", count: 39) + " c"), String(repeating: "b", count: 39))
    }

    /// Through iCloud the other devices read the same words; a kind not as this build writes it is dropped.
    func testTheEntryCrossesICloudAndADamagedOneIsDropped() throws {
        let kind = Event.sirenElsewhereKind(device: "Owner's AirPods Pro")
        let event = Event(id: UUID(), startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: kind)
        let mirrored = try XCTUnwrap(CloudExfiltrator.stateEvent(
            from: CloudExfiltrator.makeStateRecord(event, kind: kind, deviceName: "Owner's iPhone")))
        XCTAssertEqual(mirrored.sensorSummary, Self.elsewhereWords)
        let damaged = ["sirenElsewhere. Car", "sirenElsewhere.Car\n", "sirenElsewhere.Car\u{0}",
                       "sirenElsewhere." + String(repeating: "a", count: 41), "sirenElsewhere", "sirenelsewhere.Car"]
        for bad in damaged {
            XCTAssertNil(CloudExfiltrator.stateEvent(
                from: CloudExfiltrator.makeStateRecord(event, kind: bad, deviceName: "Owner's iPhone")), bad)
        }
    }

    /// The countdown no longer warns that audio goes to headphones (the owner, 2026-10-28: "remove the countdown audio
    /// warning"): in Siren mode the siren no longer goes there. Red at the step's red commit: the warning showed.
    func testTheCountdownNoLongerWarnsOfHeadphones() throws {
        let rig = makeRig(mode: .siren)
        rig.engine.sirenOutputsForTesting = [Self.airPods]
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(rig.engine.state, .arming)
        settle(0.5)   // the countdown's ticks
        XCTAssertFalse(try arming(rig).contains { $0.contains("Audio is going to") }, "no warning on the countdown")
        rig.engine.cancelArming()
    }

    /// Nor does the countdown change the audio setting any more: the siren sets its own when it starts. Red at the
    /// step's red commit: the countdown's check put the playback setting in place.
    func testTheCountdownLeavesTheAudioSettingAlone() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient)
        let rig = makeRig(mode: .siren)
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        settle(0.5)
        XCTAssertEqual(session.category, .ambient)
        rig.engine.cancelArming()
    }

    // MARK: - Helpers

    private func makeRig(mode: ResponseMode, grace: Int = 60) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = grace
        settings.requireGuidedAccess = false
        settings.responseMode = mode
        let entitlements = ProEntitlements(resolvedAs: .trial)
        var timing = EngineCharacterizationTests.fastTiming
        timing.alertDuration = 5   // the fast clock's alert would end before a test reads the siren
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements, timing: timing))
        return Rig(engine: engine, settings: settings, entitlements: entitlements)
    }

    /// Arms through grace (0 s), calibration and the review, to `.armed`.
    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "should reach .armed", file: file, line: line)
    }

    /// The log's entries whose words are `words`, or begin with them.
    private func entries(_ rig: Rig, _ words: String, prefix: Bool = false) -> Int {
        rig.engine.eventStore.events.filter { prefix ? $0.sensorSummary.hasPrefix(words) : $0.sensorSummary == words }.count
    }

    /// iOS's notice that the audio route changed, as a device connecting posts it.
    private func postRouteChange() {
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// What the real arming screen shows.
    private func arming(_ rig: Rig) throws -> [String] {
        try shownOnScreen(ArmingView()
            .environmentObject(rig.engine)
            .environmentObject(rig.entitlements)
            .environmentObject(rig.settings)).shown
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
}
