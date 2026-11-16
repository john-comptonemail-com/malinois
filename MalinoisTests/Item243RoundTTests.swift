//
//  Item243RoundTTests.swift
//  MalinoisTests
//
//  BACKLOG 243's round t (gpt6-astra-s1 on round s; the owner, 2026-11-15: "a as you recommend"): the siren's re-check is
//  a timer of a safety transition, so it goes through `Timer.commonMode` (item 73's rule, from review 2 R2.3) and keeps
//  firing while the run loop tracks a touch, a drag on the PIN pad among them.
//

import XCTest
@testable import Malinois

@MainActor
final class Item243RoundTTests: XCTestCase {

    override func tearDown() {
        SirenPlayer.recheckIntervalForTesting = nil
        super.tearDown()
    }

    /// iOS silences the alarm for an interruption and posts no end while a touch is tracked: the re-check still brings it
    /// back. The tracking is a mode of the test's own, registered as common exactly as UIKit registers its tracking mode,
    /// as item 73's test stages it (`Item73RegressionTests.testACommonModeTimerFiresWhileTheRunLoopIsTracking`).
    func testTheSirensRecheckRunsWhileTheRunLoopTracksATouch() {
        let tracking = Self.trackingMode()
        SirenPlayer.recheckIntervalForTesting = 0.2
        let siren = SirenPlayer()
        defer { siren.stop() }
        siren.start(rampUp: false)
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm sounds")
        siren.silenceForTesting()   // paused for an interruption that posts no end
        XCTAssertTrue(pump(in: tracking, until: { siren.isPlaying }, timeout: 3),
                      "the alarm came back while the run loop tracked a touch")
    }

    /// A stopped siren stays stopped while a touch is tracked: the re-check goes with it (a guard).
    func testAStoppedSirenStaysStoppedWhileATouchIsTracked() {
        let tracking = Self.trackingMode()
        SirenPlayer.recheckIntervalForTesting = 0.2
        let siren = SirenPlayer()
        siren.start(rampUp: false)
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm sounds")
        siren.stop()
        XCTAssertFalse(pump(in: tracking, until: { siren.isPlaying }, timeout: 1), "nothing brings a stopped alarm back")
    }

    /// A mode of the test's own, made one of the main run loop's common modes, as UIKit's tracking mode is.
    private static func trackingMode() -> RunLoop.Mode {
        let mode = RunLoop.Mode("com.malinois.tests.tracking-243t")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(mode.rawValue as CFString))
        return mode
    }

    /// Runs the main run loop in `mode` until `condition` holds or `timeout` passes; whether it held. A mode with nothing
    /// in it returns at once, so the loop runs again until the deadline.
    private func pump(in mode: RunLoop.Mode = .default, until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.02))
        }
        return true
    }
}
