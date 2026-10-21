//
//  Item141SirenRouteTests.swift
//  MalinoisTests
//
//  Fable's fable-2 on 1.8 (75) (BACKLOG 141): the siren plays through the iPhone's current audio output, so with
//  headphones or a Bluetooth device connected it is not heard in the room. On the owner's iPhone (2026-10-20, step 14):
//  "the siren plays only through airpods when connected, and moves to phone immediately when airpods are placed in the
//  case". Now the countdown says so while it is true, in Siren mode, and stops saying so once it is not. The check reads
//  the route iOS gives the siren's own audio setting: the Sound tripwire's, which the app keeps after a session, leaves
//  Bluetooth headphones out. Written before the change, red at that commit (against compile-only stubs).
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

    // MARK: - The rule

    /// From the iPhone itself, or with no output named: no warning.
    func testTheIPhonesOwnSpeakerRaisesNoWarning() {
        XCTAssertNil(SirenPlayer.awayWarning(outputs: [Self.speaker]))
        XCTAssertNil(SirenPlayer.awayWarning(outputs: [SirenOutput(port: .builtInReceiver, name: "Receiver")]))
        XCTAssertNil(SirenPlayer.awayWarning(outputs: []))
    }

    /// Headphones, Bluetooth, AirPlay, a car: the warning, with the name iOS gives the device.
    func testElsewhereTheWarningNamesTheDevice() throws {
        let warning = try XCTUnwrap(SirenPlayer.awayWarning(outputs: [Self.airPods]))
        XCTAssertTrue(warning.contains("Owner's AirPods Pro"), warning)
        XCTAssertTrue(warning.contains("out loud from this iPhone"), warning)
        let elsewhere: [AVAudioSession.Port] = [.headphones, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio, .HDMI,
                                                .usbAudio, .lineOut]
        for port in elsewhere {
            XCTAssertNotNil(SirenPlayer.awayWarning(outputs: [SirenOutput(port: port, name: "Device")]), port.rawValue)
        }
        XCTAssertNotNil(SirenPlayer.awayWarning(outputs: [Self.speaker, Self.airPods]), "the sound goes there too")
        let unnamed = try XCTUnwrap(SirenPlayer.awayWarning(outputs: [SirenOutput(port: .headphones, name: " ")]))
        XCTAssertTrue(unnamed.contains("headphones or another device"), unnamed)
    }

    /// The route read is the siren's own: the Sound tripwire's recording setting, which the app keeps after a session,
    /// would leave Bluetooth headphones out, so the check puts the siren's playback setting first. Nothing plays.
    func testTheCheckReadsTheRouteOfTheSirensOwnSetting() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        _ = SirenPlayer.currentOutputs()
        XCTAssertEqual(session.category, .playback)
    }

    // MARK: - The countdown

    /// In Siren mode, with AirPods taking the sound: the countdown says so, and stops saying so once the sound is back on
    /// the iPhone (step 14: the siren moves to the iPhone as soon as they go in their case).
    func testTheCountdownWarnsWhileTheSoundGoesElsewhereAndStopsWhenItComesBack() throws {
        let rig = makeRig(mode: .siren)
        rig.engine.sirenOutputsForTesting = [Self.airPods]
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(rig.engine.state, .arming)
        let warning = try XCTUnwrap(SirenPlayer.awayWarning(outputs: [Self.airPods]))
        XCTAssertTrue(try arming(rig).contains(warning), "no warning on the countdown")
        rig.engine.sirenOutputsForTesting = [Self.speaker]
        XCTAssertTrue(pump(until: { rig.engine.sirenRouteWarning == nil }, timeout: 3), "the warning outlived the AirPods")
        XCTAssertFalse(try arming(rig).contains(warning))
        rig.engine.cancelArming()
    }

    /// Connected during the countdown: the warning comes up.
    func testHeadphonesConnectedDuringTheCountdownBringTheWarning() {
        let rig = makeRig(mode: .siren)
        rig.engine.sirenOutputsForTesting = [Self.speaker]
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertNil(rig.engine.sirenRouteWarning)
        rig.engine.sirenOutputsForTesting = [Self.airPods]
        XCTAssertTrue(pump(until: { rig.engine.sirenRouteWarning != nil }, timeout: 3), "no warning for headphones connected now")
        rig.engine.cancelArming()
    }

    /// In Alert or Stealth mode there is no siren to warn about.
    func testNoWarningWithoutTheSiren() {
        for mode in [ResponseMode.alert, .stealth] {
            let rig = makeRig(mode: mode)
            rig.engine.sirenOutputsForTesting = [Self.airPods]
            rig.engine.beginArming()
            rig.engine.confirmGuidedAccessAndStartGrace()
            pump(until: { false }, timeout: 0.5)
            XCTAssertNil(rig.engine.sirenRouteWarning, mode.rawValue)
            rig.engine.cancelArming()
        }
    }

    // MARK: - Helpers

    private func makeRig(mode: ResponseMode) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        settings.responseMode = mode
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return Rig(engine: engine, settings: settings, entitlements: entitlements)
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
