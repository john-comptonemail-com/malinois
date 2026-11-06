//
//  Item190ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 190's A7 (codex-4 on aa71756) and item 187's qwen-12 (b), taken by 1.11 (item 192's step 6): two timers
//  still on the calendar clock after 1.10 moved the trip checks to uptime. The camera tripwire's pause around a capture
//  ended at a calendar time, and the gap that means the camera was cold was timed the same way, so a clock set back
//  during a pause kept frames unjudged until that time came round. The Sound tripwire's microphone-outage report timed
//  the outage on the calendar clock, so a clock set back delayed it and one set forward brought it early. The camera
//  tripwire's two now measure ContinuousClock, which no setting moves and which, as the calendar clock did, keeps
//  running while the phone sleeps (a lock still counts as a gap between frames); the outage report measures uptime,
//  as the Sound tripwire's restart backoff does since 1.10. Written before the change, red at that commit: the tests
//  drive the monitors' clocks while the calendar clock barely moves, as a clock set back would.
//

import XCTest
@testable import Malinois

@MainActor
final class Item190ReviewTests: XCTestCase {

    /// A still scene, and the same with a hand across half of it, as the camera's frame tap gives them.
    private static let scene = VisionFrame(luma: [UInt8](repeating: 100, count: VisionFrame.width * VisionFrame.height))
    private static let handAcross = VisionFrame(luma: (0..<(VisionFrame.width * VisionFrame.height)).map {
        $0 % VisionFrame.width < VisionFrame.width / 2 ? UInt8(20) : UInt8(220)
    })

    /// Calibrates `vision` on the still scene and starts it watching, its last frame read at the clock's current time.
    private func calibrateAndWatch(_ vision: VisionMonitor) {
        vision.beginCalibration()
        for _ in 0..<5 { vision.ingest(Self.scene) }
        vision.endCalibration()
        vision.start()
        vision.ingest(Self.scene)
    }

    // MARK: - The camera tripwire (A7)

    /// The pause around a capture ends after its seconds of uptime, however little the calendar clock moved: a clock
    /// set back during it no longer keeps frames unjudged. Two seconds' pause, three seconds of uptime: the next frame
    /// ends the pause and re-anchors, the settle frames pass, and a hand across the view trips.
    func testTheCapturePauseEndsByUptime() {
        var uptime: TimeInterval = 1_000
        var trips = 0
        let vision = VisionMonitor()
        vision.uptimeForTesting = { uptime }
        vision.onTrip = { _ in trips += 1 }
        calibrateAndWatch(vision)
        vision.suppress(for: 2)
        uptime += 3
        for _ in 0...VisionMonitor.settleFrames { vision.ingest(Self.scene) }   // the pause's end, then the settle frames
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 1, "the pause ended by uptime, so the hand across the view trips")
    }

    /// The gap that means the camera was cold and came back is measured on uptime: six seconds of uptime between two
    /// frames re-anchors on the second, however little the calendar clock moved, so a scene that changed meanwhile is
    /// taken as the new one rather than as a trip.
    func testTheFrameGapIsTimedByUptime() {
        var uptime: TimeInterval = 1_000
        var trips = 0
        let vision = VisionMonitor()
        vision.uptimeForTesting = { uptime }
        vision.onTrip = { _ in trips += 1 }
        calibrateAndWatch(vision)
        uptime += VisionMonitor.frameGapForResettle + 1
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 0, "six seconds of uptime since the last frame: re-anchored, not judged")
    }

    /// The control: the same frame one second of uptime after the last is judged, and trips.
    func testAFrameWithinTheGapIsJudged() {
        var uptime: TimeInterval = 1_000
        var trips = 0
        let vision = VisionMonitor()
        vision.uptimeForTesting = { uptime }
        vision.onTrip = { _ in trips += 1 }
        calibrateAndWatch(vision)
        uptime += 1
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 1, "a hand across the view, one second after the last frame, trips")
    }

    // MARK: - The Sound tripwire's outage report (qwen-12 (b))

    /// Thirty seconds of uptime with the recorder down is an outage, however little the calendar clock moved, so a
    /// clock set back no longer delays the report and one set forward no longer brings it early.
    func testTheSoundOutageIsTimedByUptime() {
        let audio = AudioMonitor()
        var uptime: TimeInterval = 1_000
        var recording = true
        var reports: [SoundHealthTracker.Report] = []
        audio.currentLevelForTesting = { -50 }
        audio.recordingForTesting = { recording }
        audio.uptimeForTesting = { uptime }
        audio.deactivateAudioSessionForTesting = {}
        audio.onHealthReport = { reports.append($0) }
        audio.start()
        let tick = audio.queuedMeterTickForTesting(calibration: false)
        tick()
        recording = false
        tick()
        uptime += 29
        tick()
        XCTAssertEqual(reports, [], "29 seconds of uptime down is not an outage yet")
        uptime += 2
        tick()
        XCTAssertEqual(reports, [.unavailable], "31 seconds of uptime down is")
        audio.stop()
    }
}
