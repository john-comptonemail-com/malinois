//
//  VisionMonitor.swift
//  Malinois
//
//  The vision tripwire (BACKLOG 16, Pro): the camera watches its own field of view for
//  movement while the session is warm — which, by the readiness policy, means plugged in
//  (Auto) or Instant mode. That coupling is the point: the feature exists only in the mode
//  where the RECORDING indicator already shows and power is external, so it costs no
//  covertness and no battery that isn't already spent. On battery the camera is cold, no
//  frames arrive, and this monitor is simply quiet (the arming screen says so).
//
//  Frames arrive from CameraController's video tap (~2 fps, 32×24 luminance). Nothing is
//  stored during monitoring — the detector keeps two tiny baselines in memory; recording
//  only begins when a trip fires the normal capture path.
//

import Foundation

@MainActor
final class VisionMonitor: SensorMonitor {
    let type: SensorType = .vision
    var isEnabled: Bool = true
    var sensitivity: Sensitivity = .medium
    var onTrip: ((SensorType) -> Void)?
    var requiresCalibration: Bool { true }

    private var detector = VisionDetector()
    private var calibrating = false
    private var watching = false
    private var hasTripped = false
    /// When the pause around a capture ends, and when the last frame was read, on `steadyNow()` (item 190's A7: on
    /// the calendar clock, a clock set back during a pause kept frames unjudged until that time came round).
    private var suppressedUntil: TimeInterval?
    private var lastFrameAt: TimeInterval?
    private var settleFramesRemaining = 0
    private var lastChanged: Double = 0
    /// Whether the engine stood the camera down (Auto unplugged, a watch going live or a capture ending on a cold camera,
    /// Test Sensors closing, a disarm) and the camera has read no frame since the engine had it up again: the row then
    /// says no frames come, not the last reading, which no camera is making now, and a frame that comes before the camera
    /// is up again counts for nothing, whatever frame was already on its way and whatever a warm-up still running brings
    /// (item 190's codex-5 on 29d6501, codex-3 on b7702f5 and on 424d8ce, codex-2 on 63e77b0, deepseek-1 on 1c083ab, the
    /// owner's "a").
    private var stoodDown = false
    /// Whether the engine has asked for the camera warm since it stood it down.
    private var warming = false
    /// Whether the engine has had the camera up since it stood it down: the warm-up it asked for has finished, or a
    /// capture has started. Only then is a frame judged, and only then does a frame read end `stoodDown`, so a frame from
    /// the camera standing down, read late, never does (codex-2 on 63e77b0, deepseek-1 on 1c083ab).
    private var warmedUp = false

    /// Whether the camera's frame tap is actually delivering, set by the engine after a
    /// warm-up. `nil` = the camera is cold (nothing was attached), `false` = a tap was asked
    /// for and did not come up — either the multi-cam session (camera position Both), or an
    /// inactive connection. The distinction matters: "no frames" with the camera cold is
    /// expected and explained on the arming screen, while "no frames" with the camera warm is
    /// a tripwire the owner enabled and is not getting.
    var tapActive: Bool?

    #if DEBUG
    /// The steady clock a test drives in place of `steadyNow()` (item 190's A7).
    var uptimeForTesting: (() -> TimeInterval)?
    #endif

    /// The clock the pause around a capture and the gap between frames are timed on, in seconds (item 190's A7):
    /// `ContinuousClock`, which no setting moves and which, like the calendar clock they were timed on before, keeps
    /// running while the phone sleeps, so a lock's whole length is still a gap between frames. (The motion and Sound
    /// tripwires' `systemUptime` stops while the phone sleeps.)
    private func steadyNow() -> TimeInterval {
        #if DEBUG
        if let uptimeForTesting { return uptimeForTesting() }
        #endif
        let elapsed = ContinuousClock.now - Self.steadyOrigin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private static let steadyOrigin = ContinuousClock.now

    /// A gap this long between frames means the camera was cold and just came back (Auto
    /// flipped to charging); the scene may have changed meanwhile, so re-anchor quietly.
    static let frameGapForResettle: TimeInterval = 5
    /// Frames to absorb after a resume/suppression before judging again.
    static let settleFrames = 3

    var tripFraction: Double { VisionDetector.tripFraction(for: sensitivity) }

    /// Entry point for every frame from the camera tap (main actor). A frame while the camera stands down, before the
    /// engine has it up again, counts for nothing: no reading, no trip, not even its time, so the first frame once the
    /// camera is up after a long cold spell still re-anchors (item 190's deepseek-1 on 1c083ab, the owner's "a").
    func ingest(_ frame: VisionFrame) {
        if stoodDown && !warmedUp { return }
        let now = steadyNow()
        let gap = lastFrameAt.map { now - $0 }
        lastFrameAt = now

        if let until = suppressedUntil {
            guard now >= until else { return }
            suppressedUntil = nil
            detector.rebaseline(to: frame)
            settleFramesRemaining = Self.settleFrames
            return
        }
        if calibrating {
            detector.calibrate(frame)
            return
        }
        guard watching else { return }
        if let gap, gap > Self.frameGapForResettle {
            detector.rebaseline(to: frame)
            settleFramesRemaining = Self.settleFrames
            return
        }
        if settleFramesRemaining > 0 {
            settleFramesRemaining -= 1
            detector.rebaseline(to: frame)
            return
        }
        switch detector.evaluate(frame, tripFraction: tripFraction) {
        case .calibrating:
            break
        case .ok(let changed):
            noteReading(changed)
        case .trip(let changed, _):
            noteReading(changed)
            guard !hasTripped else { return }
            hasTripped = true
            onTrip?(.vision)
        }
    }

    // MARK: - SensorMonitor

    func beginCalibration() { calibrating = true; detector.beginCalibration() }
    func endCalibration()   { calibrating = false; detector.endCalibration() }

    func start() {
        watching = true
        hasTripped = false
        lastFrameAt = nil
        settleFramesRemaining = 0
    }

    func stop() {
        watching = false
        hasTripped = false
        suppressedUntil = nil
    }

    func rearm() { hasTripped = false }

    /// The camera stood down: no frames come, and any that do count for nothing, until the engine has it up again and a
    /// frame is read (item 190's codex-5 on 29d6501, codex-3 on 424d8ce, codex-2 on 63e77b0, deepseek-1 on 1c083ab). The
    /// last frame's time stays, so a frame after a long cold spell still re-anchors (`frameGapForResettle`); the tap's
    /// state goes back to cold (`nil`), so a verdict on the tap from before the stand-down never speaks for a camera now
    /// cold.
    func cameraStoodDown() { stoodDown = true; warming = false; warmedUp = false; tapActive = nil }

    /// The camera is asked to warm again: the row says none come until that warm-up has finished and a frame is read
    /// (codex-3 on b7702f5 and on 424d8ce, codex-2 on 63e77b0).
    func cameraWarming() { warming = true }

    /// The warm-up the engine asked for has finished: the next frame read ends "No frames"; one finishing after a
    /// stand-down, which cancelled its request, changes nothing (codex-2 on 63e77b0, the owner's "a").
    func cameraWarmed() { if warming { warmedUp = true } }

    /// A frame read: the row's reading, the first once the warm-up the engine asked for has finished ending "No frames"; a
    /// frame that only re-anchors (around a capture, or after a long cold spell) reads nothing (codex-3 on 424d8ce,
    /// codex-2 on 63e77b0).
    private func noteReading(_ changed: Double) {
        lastChanged = changed
        if warmedUp { stoodDown = false }
    }

    /// After a real trigger the scene may legitimately be different (someone is now standing
    /// there). Adopt it, exactly as motion adopts a new resting pose, so it doesn't trip
    /// forever — their *next* movement trips again.
    func rearmAndRebaseline() {
        hasTripped = false
        detector.rebaseline()
    }

    /// Ignore frames for a while — around a capture (the scene being recorded, the screen
    /// flash, a camera reconfigure) — then re-anchor on resume. A capture has the camera up at
    /// the engine's request, so once it resumes its frames are judged, after a stand-down too
    /// (item 190's deepseek-1 on 1c083ab).
    func suppress(for interval: TimeInterval) {
        suppressedUntil = steadyNow() + interval
        warmedUp = true
    }

    func recentTrace() -> [Double] { detector.trace }

    func liveReading() -> SensorReading? {
        guard lastFrameAt != nil, !stoodDown else {
            if tapActive == false {
                // Never claim a cause that hasn't been established: with the camera warm and
                // the tap not delivering, "needs the camera warm" would be a wrong answer to
                // the owner's real question.
                return SensorReading(value: "Not running",
                                     detail: "the camera can't run this tripwire in its current setup - see the arming screen",
                                     level: 0, hot: false)
            }
            return SensorReading(value: "No frames",
                                 detail: "needs the camera warm - plugged in (Auto) or Instant mode",
                                 level: 0, hot: false)
        }
        return SensorReading(
            value: String(format: "%.0f%% of view changed", lastChanged * 100),
            detail: String(format: "trips above %.0f%%", tripFraction * 100),
            level: min(lastChanged / max(tripFraction * 2, 0.01), 1),
            hot: lastChanged > tripFraction)
    }
}
