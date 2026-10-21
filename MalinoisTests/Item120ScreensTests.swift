//
//  Item120ScreensTests.swift
//  MalinoisTests
//
//  BACKLOG 120 (1.7 (70), the top-down review of 69): what Home and the arming screens show.
//  F1: with iCloud backup off, Home's row still said "iCloud ready" and the arming and countdown
//  screens said nothing, so a phone could be armed night after night with nothing leaving it.
//  F3: the notices the ARM tap raises (a camera that is denied or fails to start, a microphone the
//  clips cannot use) reached only Home, after the disarm. F4: on a charger (Auto) or in Instant
//  mode the camera runs from the ARM tap, and the arming screens showed no REC badge. F2 (added with
//  the owner's wording): the passcode advice said someone who knows the unlock code "still can't
//  exit", though a forced restart ends the watch. Each test lays
//  out the real screen in a window (item 82's pattern) and reads what its notices and badges report
//  (`OnScreenRecorder`: SwiftUI gives a unit test no accessibility elements). The engine reaches
//  each state its own way: the backup switch through `setCloudBackup`, the notices through a
//  warm-up that fails, the camera through the session the fake reports running. Written before the
//  fixes, red at that commit. Two guards pass before and after (no backup line with backup on or on
//  the free tier; no badge with the camera off); the third, Home's iCloud row with backup on, fails
//  before only because the row did not report its text yet.
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item120ScreensTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "Item120ScreensTests")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static let iPhone17Pro = CGSize(width: 402, height: 874)
    private static let backupOff = MonitoringEngine.backupOffNotice
    /// What `RecordingIndicator` shows and reports.
    private static let recBadge = "REC"

    // MARK: - F1: iCloud backup off

    /// Home said "iCloud ready", in green, while nothing new could leave the phone. With backup off
    /// on Pro the iCloud row is the orange backup-off line instead, whatever the account says.
    func testHomeShowsBackupOffInPlaceOfTheICloudRow() throws {
        let rig = makeRig()
        XCTAssertTrue(rig.engine.setCloudBackup(false), "turned off the Settings way, while disarmed")
        let shown = try shownTexts(on: home(rig))
        XCTAssertTrue(shown.contains(Self.backupOff), "Home does not say backup is off: \(shown)")
        for row in Self.iCloudRowTexts {
            XCTAssertFalse(shown.contains(row), "Home still shows the iCloud row \"\(row)\" with backup off")
        }
    }

    /// Guard: with backup on, Home shows its iCloud row as before and no backup-off line.
    func testHomeWithBackupOnShowsTheICloudRowAndNoBackupLine() throws {
        let rig = makeRig()
        let shown = try shownTexts(on: home(rig))
        XCTAssertFalse(shown.contains(Self.backupOff))
        XCTAssertTrue(shown.contains { Self.iCloudRowTexts.contains($0) }, "no iCloud row on Home: \(shown)")
    }

    /// The Guided Access step and the countdown say it too, before the owner walks away.
    func testTheArmingScreensSayBackupIsOff() throws {
        let rig = makeRig { $0.gracePeriodSeconds = 60 }
        XCTAssertTrue(rig.engine.setCloudBackup(false))
        rig.engine.beginArming()
        XCTAssertEqual(rig.engine.state, .guidedAccessCheck)
        XCTAssertTrue(try shownTexts(on: arming(rig)).contains(Self.backupOff), "the Guided Access step is silent")
        startCountdown(rig)
        XCTAssertTrue(try shownTexts(on: arming(rig)).contains(Self.backupOff), "the countdown is silent")
        rig.engine.cancelArming()
    }

    /// Guard: no backup-off line with backup on, or on the free tier (whose own line says that
    /// evidence stays on the device).
    func testTheArmingScreensSayNothingAboutBackupWhenItIsOnOrOnTheFreeTier() throws {
        for (tier, backup) in [(ProEntitlements.Status.trial, true), (.free, false)] {
            let rig = makeRig(tier: tier) { $0.gracePeriodSeconds = 60 }
            XCTAssertTrue(rig.engine.setCloudBackup(backup))
            rig.engine.beginArming()
            XCTAssertFalse(try shownTexts(on: arming(rig)).contains(Self.backupOff), "\(tier), backup \(backup)")
            startCountdown(rig)
            XCTAssertFalse(try shownTexts(on: arming(rig)).contains(Self.backupOff), "\(tier), backup \(backup)")
            rig.engine.cancelArming()
        }
    }

    // MARK: - F3: the arm-time notices

    /// A camera that fails to warm up and a microphone the clips cannot use: the ARM tap raises both
    /// notices, and both arming screens now show them ("so the user isn't left armed but blind").
    func testTheArmingScreensShowTheNoticesTheArmTapRaises() throws {
        let rig = makeRig { $0.gracePeriodSeconds = 60 }
        rig.camera.warmUpError = NSError(domain: "Item120", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "The camera could not start."])
        rig.camera.micUnavailableForClips = true
        rig.engine.beginArming()
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil && rig.engine.audioNotice != nil }, timeout: 5),
                      "the warm-up at arming raises both notices")
        let camera = try XCTUnwrap(rig.engine.cameraNotice)
        let audio = try XCTUnwrap(rig.engine.audioNotice)
        let step = try shownTexts(on: arming(rig))
        XCTAssertTrue(step.contains(camera), "the Guided Access step does not show \"\(camera)\": \(step)")
        XCTAssertTrue(step.contains(audio), "the Guided Access step does not show \"\(audio)\": \(step)")
        startCountdown(rig)
        let countdown = try shownTexts(on: arming(rig))
        XCTAssertTrue(countdown.contains(camera), "the countdown does not show \"\(camera)\": \(countdown)")
        XCTAssertTrue(countdown.contains(audio), "the countdown does not show \"\(audio)\": \(countdown)")
        rig.engine.cancelArming()
    }

    // MARK: - F4: the REC badge

    /// In Instant mode (or Auto on a charger) the camera runs from the ARM tap: the REC badge shows
    /// on the Guided Access step and the countdown, as on the armed screen, and goes with the camera.
    func testTheArmingScreensShowTheRECBadgeWhileTheCameraRuns() throws {
        let rig = makeRig { $0.gracePeriodSeconds = 60 }
        rig.engine.beginArming()
        rig.camera.setRecordingActive(true)   // what the real camera reports once its session runs
        XCTAssertTrue(try shownTexts(on: arming(rig)).contains(Self.recBadge), "no REC badge on the Guided Access step")
        startCountdown(rig)
        XCTAssertTrue(try shownTexts(on: arming(rig)).contains(Self.recBadge), "no REC badge on the countdown")
        rig.camera.setRecordingActive(false)
        XCTAssertFalse(try shownTexts(on: arming(rig)).contains(Self.recBadge), "the badge outlives the camera")
        rig.engine.cancelArming()
    }

    /// Guard: no badge while no camera runs (Battery saver, or Auto on battery).
    func testTheArmingScreensShowNoRECBadgeWhileTheCameraIsOff() throws {
        let rig = makeRig { $0.gracePeriodSeconds = 60 }
        rig.engine.beginArming()
        XCTAssertFalse(try shownTexts(on: arming(rig)).contains(Self.recBadge))
        rig.engine.cancelArming()
    }

    // MARK: - Codex's look at 70: calibration, the recovery PIN, large text

    /// V2: calibration showed none of them, though a camera can fail after a five-second countdown
    /// (its warm-up has eight seconds) and going live warms it again. The notices show while it
    /// calibrates and on the "Calibrated" card.
    func testCalibrationShowsTheArmTimeNotices() throws {
        var calibrating = EngineCharacterizationTests.fastTiming
        calibrating.calibrationDuration = 30
        var reviewing = EngineCharacterizationTests.fastTiming
        reviewing.calibrationReview = 30
        for (phase, timing) in [("calibrating", calibrating), ("the Calibrated card", reviewing)] {
            let rig = makeRig(timing: timing)
            rig.camera.warmUpError = NSError(domain: "Item120", code: 2,
                                             userInfo: [NSLocalizedDescriptionKey: "The camera could not start."])
            rig.camera.micUnavailableForClips = true
            XCTAssertTrue(rig.engine.setCloudBackup(false))
            rig.engine.beginArming()
            XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil && rig.engine.audioNotice != nil }, timeout: 5))
            rig.engine.confirmGuidedAccessAndStartGrace()   // a countdown of 0 s
            XCTAssertTrue(pump(until: { rig.engine.state == .calibrating
                                    && rig.engine.showingCalibrationReview == (phase != "calibrating") }, timeout: 5), phase)
            let shown = try shownTexts(on: arming(rig))
            for notice in [Self.backupOff, try XCTUnwrap(rig.engine.cameraNotice), try XCTUnwrap(rig.engine.audioNotice)] {
                XCTAssertTrue(shown.contains(notice), "\(phase) does not show \"\(notice)\": \(shown)")
            }
            rig.engine.cancelArming()
        }
    }

    /// V3: tapping Cancel on a crash-recovery re-arm covers the countdown with the PIN pad, while the
    /// camera it warmed keeps running; the pad showed no REC badge.
    func testTheRecoveryPINShowsTheRECBadgeWhileTheCameraRuns() throws {
        let rig = makeRig { $0.gracePeriodSeconds = 60 }
        rig.engine.beginArming()
        rig.camera.setRecordingActive(true)
        let pin = RecoveryCancelPINView {}
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
        XCTAssertTrue(try shownTexts(on: pin).contains(Self.recBadge), "the recovery PIN hides the REC badge")
        rig.engine.cancelArming()
    }

    /// V4: at the largest accessibility text size on the iPhone Duo's outer display (387 x 645) the
    /// badge, laid over the countdown, covered "Arming in". It now takes room of its own: when the
    /// camera starts, the countdown's content moves down to make space for it.
    func testTheRECBadgeTakesRoomOfItsOwnAtTheLargestTextSize() throws {
        let rig = makeRig { $0.gracePeriodSeconds = 60 }
        rig.engine.beginArming()
        startCountdown(rig)
        let duo = CGSize(width: 387, height: 645)
        func contentTop() throws -> CGFloat {
            let screen = arming(rig).environment(\.dynamicTypeSize, .accessibility5)
            let scroller = try XCTUnwrap(try layout(of: screen, in: duo).scrollers.first,
                                         "the countdown does not scroll at this size")
            return scroller.contentTop
        }
        let withoutBadge = try contentTop()
        rig.camera.setRecordingActive(true)
        let withBadge = try contentTop()
        XCTAssertGreaterThan(withBadge, withoutBadge + 20,
                             "the countdown's content does not move down for the badge, which covers it")
        rig.engine.cancelArming()
    }

    /// Codex's second look (W1): on a short screen at the largest text size, the recovery PIN, here at its
    /// tallest (locked out after five wrong PINs), is taller than the room, and the badge's row pushed
    /// the badge above the top of the screen and Cancel below the bottom. The badge now stays on
    /// screen, and below it the PIN scrolls, so Cancel stays reachable. Read from where the badge is
    /// laid out: it still appears when it is off screen.
    func testTheRecoveryPINKeepsTheRECBadgeOnScreenAtTheLargestTextSize() throws {
        KeychainService.wipeStalePINData()
        defer { KeychainService.wipeStalePINData() }
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable in this build — skipped")
        for _ in 0..<5 { XCTAssertFalse(KeychainService.verify("0000")) }
        XCTAssertGreaterThan(KeychainService.lockoutRemaining(), 0, "locked out: the PIN at its tallest")
        let rig = makeRig { $0.gracePeriodSeconds = 60 }
        rig.engine.beginArming()
        rig.camera.setRecordingActive(true)
        for size in [CGSize(width: 387, height: 645), CGSize(width: 375, height: 667)] {
            let pin = RecoveryCancelPINView {}
                .environmentObject(rig.engine)
                .environmentObject(rig.settings)
                .environment(\.dynamicTypeSize, .accessibility5)
            let screen = try layout(of: pin, in: size)
            let badge = try XCTUnwrap(screen.frames[Self.recBadge], "no REC badge at \(size)")
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(badge),
                          "the REC badge is off screen at \(size): \(badge)")
            let pad = try XCTUnwrap(screen.scrollers.first, "the PIN does not scroll at \(size), so it is cut off")
            XCTAssertGreaterThanOrEqual(pad.contentTop, badge.maxY - 0.5, "the PIN starts under the badge at \(size)")
        }
        rig.engine.cancelArming()
    }

    // MARK: - F2: the iPhone passcode

    /// Both screens that advise a Guided Access passcode different from the device passcode said that
    /// someone who knows the unlock code "still can't exit". A forced restart ends Guided Access and
    /// the watch, and the unlock code then opens the phone. The advice now says what a different
    /// passcode does and does not stop (the owner's wording, 2026-10-15). Read as each screen shows
    /// it: the Guided Access step's setup steps (Guided Access is off in the simulator), and the
    /// prompt shown after the first watch without it.
    func testThePasscodeAdviceSaysWhatAForcedRestartStillDoes() throws {
        let rig = makeRig { $0.gracePeriodSeconds = 60 }
        rig.engine.beginArming()
        let screens: [(String, [String])] = [("the Guided Access step", try shownTexts(on: arming(rig))),
                                             ("the Guided Access prompt", try shownTexts(on: GuidedAccessPromptView {}))]
        rig.engine.cancelArming()
        for (screen, shown) in screens {
            let advice = try XCTUnwrap(shown.first { $0.contains("Passcode Settings") },
                                       "\(screen) shows no passcode advice: \(shown)")
            XCTAssertFalse(advice.contains("still can't exit"), "\(screen): \(advice)")
            XCTAssertTrue(advice.contains("can't end Guided Access"), "\(screen): \(advice)")
            XCTAssertTrue(advice.contains("A forced restart still ends the watch"), "\(screen): \(advice)")
        }
    }

    // MARK: - Rig

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
        let settings: AppSettings
        let cloud: CloudExfiltrator
        let entitlements: ProEntitlements
    }

    /// Every text Home's iCloud row can show on Pro.
    private static let iCloudRowTexts: [String] = [
        CloudExfiltrator.AccountState.unknown, .available, .noAccount, .restricted, .error("")
    ].map(\.displayName) + ["iCloud verification needed", HomeView.iCloudWaitingRow]

    private func makeRig(tier: ProEntitlements.Status = .trial, timing: EngineTiming = EngineCharacterizationTests.fastTiming,
                         _ configure: (AppSettings) -> Void = { _ in }) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.enabledSensors.insert(.camera)
        settings.cameraReadiness = .instant   // the camera warms at the ARM tap
        configure(settings)
        let camera = FakeCamera()
        let store = EventStore()
        let cloud = CloudExfiltrator()
        let entitlements = ProEntitlements(resolvedAs: tier)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: camera, entitlements: entitlements,
                                                          timing: timing))
        return Rig(engine: engine, camera: camera, store: store, settings: settings, cloud: cloud,
                   entitlements: entitlements)
    }

    private func startCountdown(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 5), "counting down", file: file, line: line)
    }

    private func home(_ rig: Rig) -> some View {
        HomeView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(rig.cloud)
            .environmentObject(rig.store)
            .environmentObject(rig.entitlements)
    }

    private func arming(_ rig: Rig) -> some View {
        ArmingView()
            .environmentObject(rig.engine)
            .environmentObject(rig.entitlements)
            .environmentObject(rig.settings)
    }

    // MARK: - Laying out a real screen

    /// The texts the reporting notices and badges of `view` show when it is laid out in a window of
    /// `size` (at the origin, safe areas ignored), read before the window closes.
    private func shownTexts<V: View>(on view: V, in size: CGSize = iPhone17Pro) throws -> [String] {
        try layout(of: view, in: size).shown
    }

    /// A scroll view on screen: where its content starts, in the window, when scrolled to the top.
    private struct Scroller {
        let contentTop: CGFloat
    }

    /// `view` laid out in a window of `size` (item 82's pattern): what its reporting views show, and
    /// its scroll views, read before the window closes.
    private func layout<V: View>(of view: V, in size: CGSize) throws
        -> (shown: [String], frames: [String: CGRect], scrollers: [Scroller]) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let recorder = OnScreenRecorder()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutIfNeeded()
        var scrollers: [Scroller] = []
        var pending: [UIView] = [window]
        while let next = pending.popLast() {
            pending.append(contentsOf: next.subviews)
            guard let scroll = next as? UIScrollView, !scroll.isHidden, scroll.alpha > 0, scroll.bounds.height > 0
            else { continue }
            let frame = scroll.convert(scroll.bounds, to: window)
            scrollers.append(Scroller(contentTop: frame.minY + scroll.adjustedContentInset.top))
        }
        return (recorder.shown, recorder.frames, scrollers)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
