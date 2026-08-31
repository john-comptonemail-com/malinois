//
//  AppSettingsTests.swift
//  MalinoisTests
//

import XCTest
import UIKit
@testable import Malinois

final class AppSettingsTests: XCTestCase {

    func testDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.illumination, .auto)
        XCTAssertTrue(s.notifyOtherDevices)
        XCTAssertEqual(s.captureMode, .clip3, "video is the default capture")
        XCTAssertEqual(s.cameraPosition, .auto,
                       "Front pointed the camera at the desk whenever the phone was placed face down")
        XCTAssertTrue(s.jammingResponse, "go-loud-if-jammed is on by default")
        XCTAssertEqual(s.responseMode, .alert, "alert message is the default response")
        XCTAssertEqual(s.alertMessage, AppSettings.defaultAlertMessage)
        XCTAssertFalse(s.isEnabled(.audio), "audio is off by default")
        XCTAssertTrue(s.isEnabled(.motion))
        XCTAssertEqual(s.cameraReadiness, .auto, "Auto (warm while charging) is the default battery mode")
        XCTAssertFalse(s.scramblePINPad, "PIN-pad scrambling is opt-in, off by default")
        XCTAssertFalse(s.biometricUnlock, "Face ID unlock is opt-in, off by default — two doors make the weaker one the boundary")
    }

    /// F-23: arming is inert with no tripwire enabled — the flag the UI warns on.
    func testHasActiveTripwire() {
        let s = AppSettings()
        s.enabledSensors = [.motion]
        XCTAssertTrue(s.hasActiveTripwire)
        s.enabledSensors = [.camera]   // camera is a capture path, not a tripwire
        XCTAssertFalse(s.hasActiveTripwire)
        s.enabledSensors = []
        XCTAssertFalse(s.hasActiveTripwire)
        s.enabledSensors = [.camera, .touch]
        XCTAssertTrue(s.hasActiveTripwire)
    }

    /// The pure battery-readiness decision drives whether the camera is kept warm.
    func testCameraReadinessKeepsWarmDecision() {
        // Instant: always warm, regardless of power.
        XCTAssertTrue(CameraReadiness.instant.keepsCameraWarm(charging: true))
        XCTAssertTrue(CameraReadiness.instant.keepsCameraWarm(charging: false))
        // Battery saver: always cold-start, regardless of power.
        XCTAssertFalse(CameraReadiness.batterySaver.keepsCameraWarm(charging: true))
        XCTAssertFalse(CameraReadiness.batterySaver.keepsCameraWarm(charging: false))
        // Auto: warm only while charging.
        XCTAssertTrue(CameraReadiness.auto.keepsCameraWarm(charging: true))
        XCTAssertFalse(CameraReadiness.auto.keepsCameraWarm(charging: false))
    }

    /// `.charging` and `.full` count as on-external-power; `.unplugged`/`.unknown` don't.
    func testChargingStateClassification() {
        XCTAssertTrue(MonitoringEngine.isChargingState(.charging))
        XCTAssertTrue(MonitoringEngine.isChargingState(.full))
        XCTAssertFalse(MonitoringEngine.isChargingState(.unplugged))
        XCTAssertFalse(MonitoringEngine.isChargingState(.unknown))
    }

    func testCodableRoundTripPreservesFields() throws {
        let s = AppSettings()
        s.illumination = .on
        s.notifyOtherDevices = false
        s.jammingResponse = false
        s.gracePeriodSeconds = 30
        s.captureMode = .clip5
        s.cameraPosition = .both
        s.cameraReadiness = .batterySaver
        s.enabledSensors = [.motion, .audio]
        s.sensitivities[.motion] = .high
        s.responseMode = .siren
        s.alertMessage = "Custom warning"
        s.scramblePINPad = true

        let data = try JSONEncoder().encode(s)
        let d = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(d.illumination, .on)
        XCTAssertFalse(d.notifyOtherDevices)
        XCTAssertFalse(d.jammingResponse)
        XCTAssertEqual(d.gracePeriodSeconds, 30)
        XCTAssertEqual(d.captureMode, .clip5)
        XCTAssertEqual(d.cameraPosition, .both)
        XCTAssertEqual(d.cameraReadiness, .batterySaver)
        XCTAssertEqual(d.enabledSensors, [.motion, .audio])
        XCTAssertEqual(d.sensitivity(for: .motion), .high)
        XCTAssertEqual(d.responseMode, .siren)
        XCTAssertEqual(d.alertMessage, "Custom warning")
        XCTAssertTrue(d.scramblePINPad)
    }

    /// A settings blob saved by a build that still had the removed `motionCorroborated`
    /// trigger mode must NOT fail to decode. A hard `decode` would throw on the retired raw
    /// value, failing the whole AppSettings decode — and `load()`'s `try?` would then reset
    /// EVERY setting, not just this one. It must fall back to `.any` and keep the rest.
    func testRetiredTriggerModeFallsBackWithoutWipingOtherSettings() throws {
        let json = Data("""
        {"enabledSensors":["motion","audio"],"sensitivities":[],"triggerMode":"motionCorroborated",\
        "gracePeriodSeconds":45,"captureMode":"clip5","alertMessage":"Custom warning",\
        "deviceLabel":"Desk iPhone","notifyOtherDevices":false}
        """.utf8)
        let d = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(d.triggerMode, .any, "the retired mode maps to the only remaining one")
        // The rest of the user's configuration must survive intact.
        XCTAssertEqual(d.gracePeriodSeconds, 45)
        XCTAssertEqual(d.captureMode, .clip5)
        XCTAssertEqual(d.alertMessage, "Custom warning")
        XCTAssertEqual(d.deviceLabel, "Desk iPhone")
        XCTAssertFalse(d.notifyOtherDevices)
        XCTAssertEqual(d.enabledSensors, [.motion, .audio])
    }

    func testLegacyCaptureModeRawValue() {
        XCTAssertEqual(CaptureMode(rawValue: "clip"), .clip3, "old '3-second clip' raw value migrates")
    }

    func testDecodeAppliesDefaultsForMissingNewKeys() throws {
        // Also covers backward compatibility: the JSON still carries the removed
        // `requireGuidedAccess` key, which must now be ignored rather than fail.
        let json = Data("""
        {"enabledSensors":["motion"],"sensitivities":[],"triggerMode":"any",\
        "gracePeriodSeconds":15,"captureMode":"photo","requireGuidedAccess":true}
        """.utf8)
        let d = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(d.illumination, .auto)
        XCTAssertTrue(d.notifyOtherDevices)
        XCTAssertEqual(d.cameraPosition, .auto,
                       "the decode fallback has to agree with the initialiser's default")
        XCTAssertEqual(d.cameraReadiness, .auto, "settings saved before battery mode existed default to Auto")
        XCTAssertFalse(d.scramblePINPad, "PIN-pad scrambling is off by default and for pre-existing settings")
        XCTAssertFalse(d.biometricUnlock, "Face ID unlock decodes off for settings saved before it existed")
    }

    // MARK: - Pro gating (paywall spec)

    /// Audio is the only Pro *tripwire*; every other sensor stays free so the free tier still
    /// detects the primary threats. Pro is a pass-through.
    func testEffectiveSensorsGateOnlyProTripwires() {
        let all: Set<SensorType> = [.motion, .power, .proximity, .touch, .audio, .vision]
        XCTAssertEqual(AppSettings.effectiveSensors(all, pro: true), all, "Pro keeps everything")
        XCTAssertEqual(AppSettings.effectiveSensors(all, pro: false),
                       [.motion, .power, .proximity, .touch], "free drops audio and vision")
        // Motion — the primary threat — is never gated.
        XCTAssertTrue(AppSettings.effectiveSensors([.motion], pro: false).contains(.motion))
    }

    /// Drift guard. The Pro pair is declared once in `SensorType.proTripwires` and read from
    /// three unrelated places: this clamp, the Settings row, and the Test Sensors row. If the
    /// clamp and the declaration ever disagree, the failure is silent and nasty — a toggle
    /// reads ON, the sensor never runs at arm time, and a clean event log looks like proof
    /// that nothing happened. Derived from `allCases` so a newly added sensor is covered
    /// automatically rather than needing this test updated.
    func testEffectiveSensorsStripsExactlyTheDeclaredProTripwires() {
        let all = Set(SensorType.allCases)
        let stripped = all.subtracting(AppSettings.effectiveSensors(all, pro: false))
        XCTAssertEqual(stripped, SensorType.proTripwires,
                       "the entitlement clamp must strip exactly SensorType.proTripwires — no more, no less")
        XCTAssertEqual(AppSettings.effectiveSensors(all, pro: true), all,
                       "Pro is a pass-through regardless of what is declared Pro")
    }

    /// Multi-cam ("Both") clamps to front on the free tier; single-camera choices pass through.
    func testEffectiveCameraClampsBothToFront() {
        XCTAssertEqual(AppSettings.effectiveCamera(.both, pro: false), .front)
        XCTAssertEqual(AppSettings.effectiveCamera(.both, pro: true), .both)
        for c in [CameraChoice.front, .rear, .auto] {
            XCTAssertEqual(AppSettings.effectiveCamera(c, pro: false), c, "single-camera choices are free")
        }
    }

    /// Longer video (5s / until-clear) clamps to the free 3s clip; photo and 3s pass through.
    func testEffectiveCaptureClampsLongerVideoToThreeSecondClip() {
        XCTAssertEqual(AppSettings.effectiveCapture(.clip5, pro: false), .clip3)
        XCTAssertEqual(AppSettings.effectiveCapture(.untilClear, pro: false), .clip3)
        XCTAssertEqual(AppSettings.effectiveCapture(.photo, pro: false), .photo, "photo is free")
        XCTAssertEqual(AppSettings.effectiveCapture(.clip3, pro: false), .clip3, "3s clip is free")
        XCTAssertEqual(AppSettings.effectiveCapture(.untilClear, pro: true), .untilClear, "Pro keeps it")
    }

    /// A free user whose ONLY enabled tripwire is the Pro audio sensor has no *effective*
    /// tripwire and must trip the warning — otherwise arming would be silently inert.
    func testProAwareTripwireWarnsWhenOnlyAudioEnabledOnFree() {
        let s = AppSettings()
        s.enabledSensors = [.audio]
        XCTAssertFalse(s.hasActiveTripwire(pro: false), "audio-only is inert without Pro")
        XCTAssertTrue(s.hasActiveTripwire(pro: true), "with Pro the audio tripwire counts")
        s.enabledSensors = [.audio, .motion]
        XCTAssertTrue(s.hasActiveTripwire(pro: false), "motion still protects the free tier")
    }

    /// Cloud backup and cross-device push are Pro-only, regardless of the saved toggle.
    func testCloudAndCrossDeviceAreProOnly() {
        let s = AppSettings()
        s.notifyOtherDevices = true
        XCTAssertFalse(s.cloudEnabled(pro: false))
        XCTAssertTrue(s.cloudEnabled(pro: true))
        XCTAssertFalse(s.notifyOtherDevicesEffective(pro: false), "no cross-device push on free")
        XCTAssertTrue(s.notifyOtherDevicesEffective(pro: true))
    }

    /// The 30-day trial window: open within 30 days of the start, closed after, and never
    /// active without a recorded start. A backward device clock fails toward the user.
    func testTrialWindow() {
        let start = Date()
        XCTAssertFalse(ProEntitlements.trialActive(start: nil, now: start), "no start → not in trial")
        XCTAssertTrue(ProEntitlements.trialActive(start: start, now: start.addingTimeInterval(29 * 86_400)))
        XCTAssertFalse(ProEntitlements.trialActive(start: start, now: start.addingTimeInterval(31 * 86_400)))
        // Exactly at the boundary is expired (>= 30 days).
        XCTAssertFalse(ProEntitlements.trialActive(start: start, now: start.addingTimeInterval(30 * 86_400)))
        // Clock moved earlier than the start → still active, not expired early.
        XCTAssertTrue(ProEntitlements.trialActive(start: start, now: start.addingTimeInterval(-10 * 86_400)))
    }

    // MARK: - Onboarding

    /// The Guided Access nudge is deliberately narrow: once, only after a session that actually
    /// ran, and never to an owner who already has Guided Access on. A security prompt shown to
    /// someone who has already done the thing is how prompts get trained into reflexive
    /// dismissal — which costs more than the nudge gains.
    func testGuidedAccessPromptFiresOnceAndNeverWhenAlreadySecured() {
        // The case it exists for: a completed session with Guided Access off.
        XCTAssertTrue(OnboardingState.shouldPromptForGuidedAccess(
            completedASession: true, guidedAccessOn: false, alreadySeen: false))

        // Already using Guided Access → never nag.
        XCTAssertFalse(OnboardingState.shouldPromptForGuidedAccess(
            completedASession: true, guidedAccessOn: true, alreadySeen: false),
                       "an owner who already enabled Guided Access must not be told they're unprotected")

        // Shown before → once only.
        XCTAssertFalse(OnboardingState.shouldPromptForGuidedAccess(
            completedASession: true, guidedAccessOn: false, alreadySeen: true))

        // Arming cancelled before the watch went live is not a completed session, so the prompt
        // must not fire off the back of it.
        XCTAssertFalse(OnboardingState.shouldPromptForGuidedAccess(
            completedASession: false, guidedAccessOn: false, alreadySeen: false))
    }

    // MARK: - The launch window before entitlement is known

    /// Reported from TestFlight 2026-08-26: opening the app flashed "Pro trial ended" with a
    /// $9.99 upsell before settling on the trial that was still active. `status` starts `.free`
    /// — the right default for capability, since nothing should unlock before entitlement is
    /// proven — but read as messaging it says "this owner has no entitlement" during every
    /// launch's StoreKit round trip.
    func testTrialEndedStaysQuietUntilEntitlementIsActuallyKnown() {
        XCTAssertFalse(ProEntitlements.trialHasEnded(status: .free, hasTrialStart: true,
                                                     hasResolved: false),
                       "an unchecked entitlement must never announce a downgrade")
        XCTAssertTrue(ProEntitlements.trialHasEnded(status: .free, hasTrialStart: true,
                                                    hasResolved: true),
                      "once resolved, a free status with a recorded start is a used-up trial")
    }

    func testAnActiveTrialOrPurchaseNeverReportsTheTrialEnded() {
        XCTAssertFalse(ProEntitlements.trialHasEnded(status: .trial, hasTrialStart: true,
                                                     hasResolved: true))
        XCTAssertFalse(ProEntitlements.trialHasEnded(status: .pro, hasTrialStart: true,
                                                     hasResolved: true))
        XCTAssertFalse(ProEntitlements.trialHasEnded(status: .free, hasTrialStart: false,
                                                     hasResolved: true),
                       "no recorded start means the trial was never begun, not that it lapsed")
    }

    /// Front-as-default pointed the camera at the desk whenever the phone was placed face
    /// down — a natural covert placement, since the screen is hidden — so captures came back
    /// black and the vision tripwire saw nothing, with no indication either way. Auto resolves
    /// face-down → rear and is re-resolved at every capture, so it is never worse: face up it
    /// picks front regardless.
    func testCameraDefaultsToAutoSoAFaceDownPhoneStillSees() {
        XCTAssertEqual(AppSettings().cameraPosition, .auto)
    }

    // MARK: - A corrupt settings blob must not silently reset everything (review finding 16)

    /// One malformed or wrongly-typed field made the whole decode throw, and every unrelated
    /// setting reverted with it — Guided Access enforcement, PIN-pad scrambling, which tripwires
    /// are on, the response mode. All of those default to the *less* protective value, so a
    /// silent reset quietly reduces protection, which is the one thing this app's settings must
    /// never do without saying so.
    func testACorruptSettingsBlobIsPreservedAndAnnounced() throws {
        let key = "com.malinois.settings"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set(Data("{\"gracePeriodSeconds\":\"not a number\"}".utf8), forKey: key)
        let loaded = AppSettings.load()

        XCTAssertTrue(AppSettings.loadWasReset, "the owner has to be told their settings went back to defaults")
        XCTAssertEqual(loaded.gracePeriodSeconds, AppSettings().gracePeriodSeconds)
        XCTAssertNil(UserDefaults.standard.data(forKey: key), "the unreadable blob is not left to be written over")

        let stashed = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(key + ".corrupt-") }
        XCTAssertFalse(stashed.isEmpty, "and it is preserved, in case the bytes are recoverable by hand")
        stashed.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    // MARK: - Cloud retention policy (32.R2)

    /// Settings saved before the policy existed decode to the default (auto, 12 months) —
    /// and an unknown future case degrades to the default instead of resetting everything.
    func testCloudRetentionDefaultsAndRoundTrip() throws {
        let fresh = AppSettings()
        XCTAssertEqual(fresh.cloudRetention, .months12, "the default is the least destructive auto value")

        // Round trip preserves an explicit choice.
        fresh.cloudRetention = .manual
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(fresh))
        XCTAssertEqual(decoded.cloudRetention, .manual)

        // A blob with no cloudRetention key (pre-1.2) decodes to the default.
        // Force cast: deserializing JSONEncoder's own output of a struct, which is
        // always a dictionary — and in a test, a crash is a failure like any other.
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fresh)) as! [String: Any] // swiftlint:disable:this force_cast
        dict.removeValue(forKey: "cloudRetention")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: legacy).cloudRetention,
                       .months12)
    }

    /// Seventh-review #6, the settings half: corrupt-load stashes accumulated in
    /// UserDefaults forever. load() now reaps aged ones through the shared tombstone rule.
    func testLoadReapsAgedCorruptStashes() {
        let defaults = UserDefaults.standard
        let prefix = "com.malinois.settings.corrupt-"
        let ancient = prefix + "1000000000"                          // 2001 - long past the month
        let freshStamp = Int(Date().timeIntervalSince1970) - 60      // a minute ago
        let fresh = prefix + String(freshStamp)
        defaults.set(Data([1]), forKey: ancient)
        defaults.set(Data([2]), forKey: fresh)
        defer { defaults.removeObject(forKey: fresh) }

        _ = AppSettings.load()

        XCTAssertNil(defaults.object(forKey: ancient), "the aged stash is reaped at load")
        XCTAssertNotNil(defaults.object(forKey: fresh), "a recent stash survives - the owner gets a month")
    }
}
