//
//  VisionDetector.swift
//  Malinois
//
//  The pure decision core of the vision tripwire (BACKLOG 16). It only ever sees tiny
//  downsampled luminance frames (32×24) and has no AVFoundation dependency, so every
//  decision is unit-testable with synthetic frames.
//
//  Three properties it is built around:
//  1. Mean-normalized differencing — each frame has its mean luminance subtracted before
//     comparison, so a global brightness change (auto-exposure settling, lights dimming, the
//     capture flash) is NOT motion. This is the main defence against the *illegible* false
//     positive: a trip whose photo shows an empty room.
//  2. A slow rolling baseline that adapts to legitimate scene change, clamped per pixel to
//     the calibrated session anchor — the AudioMonitor's anti-poisoning clamp, in 2-D.
//  3. A session anchor (the calibrated frame, moved only on a real trigger) with its own
//     cumulative limit, so sub-threshold creep can't ratchet an intruder into the baseline
//     one frame at a time — the MotionMonitor's session-tilt defence, in 2-D.
//

import Foundation

/// A downsampled luminance frame — the only thing the tripwire looks at.
struct VisionFrame: Equatable {
    static let width = 32
    static let height = 24
    /// Row-major, width × height.
    let luma: [UInt8]
    var count: Int { luma.count }
}

struct VisionDetector {

    enum Verdict: Equatable {
        case calibrating
        case ok(changed: Double)
        case trip(changed: Double, sessionChanged: Double)
    }

    // MARK: - Tunables (static so tests and the README can pin them)

    /// A pixel counts as "changed" when it differs from the baseline by more than
    /// noise × this multiplier — but never less than `minPixelDelta` luma units.
    static let pixelNoiseMultiplier: Double = 3
    static let minPixelDelta: Double = 12
    /// Calibrated per-pixel noise is clamped into this range (luma units), like the motion
    /// noise floor: a jittery calibration can't set an unreachable bar, a dead-still one
    /// can't set a hair trigger.
    static let minNoise: Double = 1
    static let maxNoise: Double = 12
    /// Cumulative change from the *session anchor* that trips regardless of the rolling
    /// comparison — the anti-ratchet limit.
    static let sessionLimitFraction: Double = 0.35
    /// How far (luma units) the rolling baseline may drift from the session anchor.
    static let maxRollingDrift: Double = 30
    /// Rolling-baseline adaptation per frame (~10 s time constant at 2 fps).
    static let rollingAlpha: Double = 0.05
    static let traceCapacity = 30

    /// Fraction of the frame that must change to trip, per sensitivity.
    static func tripFraction(for s: Sensitivity) -> Double {
        switch s {
        case .high:   return 0.02
        case .medium: return 0.05
        case .low:    return 0.12
        }
    }

    // MARK: - State

    private(set) var sessionBaseline: [Double] = []
    private(set) var rolling: [Double] = []
    private(set) var noise: Double = VisionDetector.minNoise
    private(set) var calibrating = false
    /// Changed-fraction per evaluated frame — the `visionTrace` stored on events, so a trip
    /// can always show *why* it fired even when the photo looks empty.
    private(set) var trace: [Double] = []
    private var calibrationFrames: [[Double]] = []
    private var lastFrame: [Double]?

    var hasBaseline: Bool { !sessionBaseline.isEmpty }
    var pixelThreshold: Double { max(noise * Self.pixelNoiseMultiplier, Self.minPixelDelta) }

    // MARK: - Pure helpers

    /// Luma with the frame mean removed — global illumination changes cancel out.
    static func normalized(_ f: VisionFrame) -> [Double] {
        guard f.count > 0 else { return [] }
        let mean = f.luma.reduce(0.0) { $0 + Double($1) } / Double(f.count)
        return f.luma.map { Double($0) - mean }
    }

    static func clampedNoise(_ measured: Double) -> Double {
        min(max(measured, minNoise), maxNoise)
    }

    /// The rolling baseline may track the scene, but never past the anchor ± maxDrift.
    static func clampedRolling(_ proposed: Double, anchor: Double, maxDrift: Double) -> Double {
        min(max(proposed, anchor - maxDrift), anchor + maxDrift)
    }

    /// Fraction of pixels differing from `ref` by more than `threshold`.
    static func changedFraction(_ f: [Double], against ref: [Double], threshold: Double) -> Double {
        guard !ref.isEmpty, ref.count == f.count else { return 0 }
        var changed = 0
        for i in 0..<f.count where abs(f[i] - ref[i]) > threshold { changed += 1 }
        return Double(changed) / Double(f.count)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count.isMultiple(of: 2) ? (s[s.count / 2 - 1] + s[s.count / 2]) / 2 : s[s.count / 2]
    }

    // MARK: - Calibration

    mutating func beginCalibration() {
        calibrating = true
        calibrationFrames.removeAll()
        // Drop the previous session's scene as well as its frames. `endCalibration` returns
        // early when no frames arrived — which happens whenever the camera never came up during
        // the calibration window — and used to leave the old baseline standing, so the next
        // frame was judged against a scene from another session in another place. Clearing here
        // makes "no frames" degrade to *no baseline*, which `evaluate` reports as `.calibrating`
        // and which seeds from the first watched frame instead.
        sessionBaseline = []   // `hasBaseline` is `!sessionBaseline.isEmpty`
        rolling = []
    }

    mutating func calibrate(_ frame: VisionFrame) {
        guard calibrating else { return }
        calibrationFrames.append(Self.normalized(frame))
    }

    /// Baseline = per-pixel mean of the calibration frames; noise = median per-pixel mean
    /// absolute deviation, clamped. With no frames (camera was cold) the detector keeps no
    /// baseline and seeds itself from the first watched frame instead.
    mutating func endCalibration() {
        calibrating = false
        defer { calibrationFrames.removeAll() }
        guard let first = calibrationFrames.first, !first.isEmpty else { return }
        let n = Double(calibrationFrames.count)
        let px = first.count
        var mean = [Double](repeating: 0, count: px)
        for fr in calibrationFrames where fr.count == px { for i in 0..<px { mean[i] += fr[i] } }
        for i in 0..<px { mean[i] /= n }
        var dev = [Double](repeating: 0, count: px)
        for fr in calibrationFrames where fr.count == px { for i in 0..<px { dev[i] += abs(fr[i] - mean[i]) } }
        for i in 0..<px { dev[i] /= n }
        noise = Self.clampedNoise(Self.median(dev) ?? 0)
        sessionBaseline = mean
        rolling = mean
    }

    /// Adopt a frame (or the last one seen) as the new anchor AND rolling baseline. Used on a
    /// real trigger (a scene left changed shouldn't trip forever — same as motion re-posing)
    /// and when frames resume after the camera was cold.
    mutating func rebaseline(to frame: VisionFrame? = nil) {
        if let frame { lastFrame = Self.normalized(frame) }
        guard let lf = lastFrame, !lf.isEmpty else { return }
        sessionBaseline = lf
        rolling = lf
    }

    // MARK: - Watching

    mutating func evaluate(_ frame: VisionFrame, tripFraction: Double) -> Verdict {
        let f = Self.normalized(frame)
        lastFrame = f
        guard hasBaseline, rolling.count == f.count else {
            rebaseline()                      // seed from this frame; next one is judged
            return .calibrating
        }
        let t = pixelThreshold
        let changed = Self.changedFraction(f, against: rolling, threshold: t)
        let sessionChanged = Self.changedFraction(f, against: sessionBaseline, threshold: t)
        trace.append(changed)
        if trace.count > Self.traceCapacity { trace.removeFirst() }

        if changed > tripFraction || sessionChanged > Self.sessionLimitFraction {
            return .trip(changed: changed, sessionChanged: sessionChanged)
        }
        // Adapt slowly to legitimate change, never beyond the anchor's drift budget.
        for i in 0..<rolling.count {
            let proposed = rolling[i] + Self.rollingAlpha * (f[i] - rolling[i])
            rolling[i] = Self.clampedRolling(proposed, anchor: sessionBaseline[i], maxDrift: Self.maxRollingDrift)
        }
        return .ok(changed: changed)
    }

    // MARK: - Downsampling (the only place raw camera geometry is touched)

    /// Box-averages a luminance plane down to the detector's frame size, sampling every
    /// other pixel for cheapness — at 2 fps the cost is negligible either way.
    static func downsample(plane: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
                           bytesPerRow: Int) -> VisionFrame {
        let tw = VisionFrame.width, th = VisionFrame.height
        var out = [UInt8](repeating: 0, count: tw * th)
        guard width >= tw, height >= th, plane.count >= bytesPerRow * height else {
            // An undersized source yields an all-zero frame, which reads as "nothing ever
            // moves" — a silently dead tripwire, not an error (seventh review, #8). It is
            // unreachable today (the session delivers 1080p, pinned by test); if a future
            // camera config ever lands here, say so out loud. 2 fps of error lines in a
            // should-never state is the loudest useful signal, not spam.
            Log.camera.error("Vision downsample: source \(width)x\(height) below the \(tw)x\(th) grid — detector blind")
            return VisionFrame(luma: out)
        }
        let cw = width / tw, ch = height / th
        for ty in 0..<th {
            for tx in 0..<tw {
                var sum = 0, n = 0
                var y = ty * ch
                while y < (ty + 1) * ch {
                    let row = y * bytesPerRow
                    var x = tx * cw
                    while x < (tx + 1) * cw {
                        sum += Int(plane[row + x]); n += 1
                        x += 2
                    }
                    y += 2
                }
                out[ty * tw + tx] = UInt8(clamping: sum / max(n, 1))
            }
        }
        return VisionFrame(luma: out)
    }
}
