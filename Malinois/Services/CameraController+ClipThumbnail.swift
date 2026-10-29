//
//  CameraController+ClipThumbnail.swift
//  Malinois
//
//  A clip's thumbnail chosen by what changed in it (BACKLOG 154, the owner's idea and his refinement; 1.8.2's step
//  35). It was the frame about 1 s in, often the empty room a Vision trip had just seen change, or the darkest frames.
//  The finished clip is sampled two frames a second from its start, 24 at most, each sample scored with the Vision
//  tripwire's own measure against the clip's first frame, and the first sample reaching 80% of the clip's greatest
//  score is shown; the frame about 1 s in stays for a clip too short to sample twice, or one where nothing changed.
//  Every wait on AVFoundation here has a limit (codex-14 on 1.8.2): this runs on the store's queue, which saves the clip
//  and which a clip trip's response waits for before it re-arms and alerts, so an answer that never comes costs the
//  thumbnail, never the save.
//

import AVFoundation
import CoreGraphics
import Foundation

extension CameraController {
    /// A sampled frame of a finished clip, and when in the clip it is.
    struct ClipFrame {
        let seconds: Double
        let image: CGImage
    }

    /// A frame AVFoundation handed back: the time asked for, the time it shows, and the picture.
    struct SampledFrame {
        let requested: Double
        let actual: Double
        let image: CGImage
    }

    /// What sampling a clip came to: the frame chosen by content, the sample at 1 s (the old choice, ready for the
    /// fallback), and whether AVFoundation ran out of time with too little back to choose from.
    struct ClipSampling {
        var chosen: ClipFrame?
        var frameAboutOneSecondIn: CGImage?
        var outOfTime = false
    }

    #if DEBUG
    /// Test-only (codex-14 on 1.8.2): AVFoundation never answers, neither the clip's length nor its frames.
    nonisolated(unsafe) static var thumbnailStallsForTesting = false
    #endif

    /// Two samples a second, from the clip's start (the owner's refinement).
    static let thumbnailSampleInterval = 0.5
    /// At most 24 samples: a longer clip (Until clear runs to two minutes) is sampled over its first 12 s, where the
    /// trip that started it is.
    static let maxThumbnailSamples = 24
    /// How long the store's queue waits on AVFoundation for a thumbnail (codex-14 on 1.8.2): the clip's length when the
    /// caller does not know it (a capture hands it over measured, a download does not), all the samples together,
    /// and the old fallback's frames. Generous for a phone: a 5 s full-HD clip's ten samples took 0.06 s on the
    /// Simulator.
    static let thumbnailLengthBudget: TimeInterval = 1
    static let thumbnailSamplingBudget: TimeInterval = 1.5
    static let thumbnailFallbackBudget: TimeInterval = 1

    /// Pure (unit-tested): the sample to show, the first whose score reaches 80% of the clip's greatest (the greatest
    /// is often a hand over the lens or a blur, and the first frame near it is where the subject has arrived); none
    /// when even the greatest is below the most sensitive trip's fraction (2%), when nothing in the clip changed.
    static func thumbnailSampleIndex(scores: [Double]) -> Int? {
        guard let peak = scores.max(), peak >= VisionDetector.tripFraction(for: .high) else { return nil }
        return scores.firstIndex { $0 >= 0.8 * peak }
    }

    /// Pure (unit-tested): each sample's score, the Vision tripwire's measure (`changedFraction` of mean-normalized
    /// cells, so a change of light over the whole frame scores nothing) against the clip's own first frame, at the
    /// tripwire's least threshold (no calibration measured the clip's noise). The clip's first frame rather than the
    /// session's baseline: a lit clip would read as wholly changed, and the Both option's second camera has none.
    static func changeScores(_ frames: [VisionFrame]) -> [Double] {
        guard let first = frames.first else { return [] }
        let reference = VisionDetector.normalized(first)
        let threshold = max(VisionDetector.minNoise * VisionDetector.pixelNoiseMultiplier, VisionDetector.minPixelDelta)
        return frames.map {
            VisionDetector.changedFraction(VisionDetector.normalized($0), against: reference, threshold: threshold)
        }
    }

    /// A clip's thumbnail picture (`videoThumbnail` makes it a JPEG): the frame chosen by content, else the frame about
    /// 1 s in (0.3 s or 0 s for a shorter clip), else none. `duration` is the clip's measured length when the caller has
    /// it. Nil, without the old fallback's wait, when AVFoundation ran out of time with fewer than two samples back;
    /// after samples that chose nothing and held none at 1 s, the fallback still runs, within its own budget.
    static func clipThumbnailImage(of url: URL, duration: Double?, maxDimension: CGFloat) -> CGImage? {
        let sampling = contentSampling(of: url, duration: duration, maxDimension: maxDimension)
        if let chosen = sampling.chosen { return chosen.image }
        if let aboutOneSecondIn = sampling.frameAboutOneSecondIn { return aboutOneSecondIn }
        guard !sampling.outOfTime else { return nil }
        let fallback = [1.0, 0.3, 0.0]
        let frames = boundedFrames(of: url, at: fallback, exact: false, maxDimension: maxDimension,
                                   budget: thumbnailFallbackBudget).frames
        for seconds in fallback {
            if let frame = frames.first(where: { $0.requested == seconds }) { return frame.image }
        }
        return nil
    }

    /// The finished clip's frame most likely to show something, or nil (unit-tested on synthetic clips).
    static func contentFrame(of url: URL, maxDimension: CGFloat = 200) -> ClipFrame? {
        contentSampling(of: url, duration: nil, maxDimension: maxDimension).chosen
    }

    /// Samples the clip at `thumbnailSampleInterval` from the start, at most `maxThumbnailSamples`, each at its exact
    /// time, scores what came back within the budget by `changeScores`, and chooses by `thumbnailSampleIndex`.
    static func contentSampling(of url: URL, duration known: Double?, maxDimension: CGFloat) -> ClipSampling {
        let duration: Double
        if let known, known.isFinite, known > 0 {
            duration = known
        } else {
            switch clipLength(of: url) {
            case .seconds(let seconds): duration = seconds
            case .unreadable: return ClipSampling()
            case .outOfTime: return ClipSampling(outOfTime: true)
            }
        }
        let times = Array(stride(from: 0.0, to: duration, by: thumbnailSampleInterval).prefix(maxThumbnailSamples))
        guard times.count >= 2 else { return ClipSampling() }
        let sampled = boundedFrames(of: url, at: times, exact: true, maxDimension: maxDimension,
                                    budget: thumbnailSamplingBudget)
        let aboutOneSecondIn = sampled.frames.first { $0.requested == 1.0 }?.image
        var samples: [(frame: ClipFrame, cells: VisionFrame)] = []
        for frame in sampled.frames {
            guard let cells = visionFrame(of: frame.image) else { continue }
            samples.append((ClipFrame(seconds: frame.actual, image: frame.image), cells))
        }
        guard samples.count >= 2 else {
            return ClipSampling(frameAboutOneSecondIn: aboutOneSecondIn, outOfTime: !sampled.complete)
        }
        let index = thumbnailSampleIndex(scores: changeScores(samples.map { $0.cells }))
        return ClipSampling(chosen: index.map { samples[$0].frame }, frameAboutOneSecondIn: aboutOneSecondIn)
    }

    /// The frames AVFoundation hands back within `budget` seconds for `times`, in the order asked, and whether every
    /// time was answered; what is still outstanding then is cancelled, and a late answer is dropped. The answers come
    /// on AVFoundation's own queue, so the store's queue waits here at most the budget.
    static func boundedFrames(of url: URL, at times: [Double], exact: Bool, maxDimension: CGFloat,
                              budget: TimeInterval) -> (frames: [SampledFrame], complete: Bool) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        if exact {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        let answers = FrameAnswers(expected: times.count)
        let done = DispatchSemaphore(value: 0)
        #if DEBUG
        let stalls = thumbnailStallsForTesting
        #else
        let stalls = false
        #endif
        if !stalls {
            let requests = times.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
            generator.generateCGImagesAsynchronously(forTimes: requests) { requested, image, actual, result, _ in
                if answers.record(requested: requested.seconds, actual: actual.seconds,
                                  image: result == .succeeded ? image : nil) {
                    done.signal()
                }
            }
        }
        let complete = done.wait(timeout: .now() + budget) == .success
        if !complete { generator.cancelAllCGImageGeneration() }
        return (answers.close(), complete)
    }

    /// A sample's cells for the scorer: its grey drawn into a plane of six pixels to a cell (192 by 144), whatever the
    /// frame's shape, then the tripwire's own downsampling. Drawn at its own size, a 200-pixel frame lost its edges: the
    /// downsampling takes whole cells, and the rest of a 200 by 113 frame, 15% of it, was never scored (codex-15 on
    /// 1.8.2). The camera's frames the tripwire itself reads divide evenly, so it is unchanged.
    private static func visionFrame(of image: CGImage) -> VisionFrame? {
        let width = VisionFrame.width * 6, height = VisionFrame.height * 6
        var plane = [UInt8](repeating: 0, count: width * height)
        let drawn = plane.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return plane.withUnsafeBufferPointer {
            VisionDetector.downsample(plane: $0, width: width, height: height, bytesPerRow: width)
        }
    }

    /// A clip's length as AVFoundation reads it, or why there is none.
    enum ClipLength {
        case seconds(Double)
        case unreadable
        case outOfTime
    }

    /// The clip's length, read with AVFoundation's asynchronous call (the synchronous one is deprecated since iOS 16),
    /// which the store's queue, not being a Swift task, waits for: at most `thumbnailLengthBudget`.
    private static func clipLength(of url: URL) -> ClipLength {
        let answer = ClipLengthAnswer()
        let done = DispatchSemaphore(value: 0)
        #if DEBUG
        let stalls = thumbnailStallsForTesting
        #else
        let stalls = false
        #endif
        if !stalls {
            Task.detached {
                let duration = try? await AVURLAsset(url: url).load(.duration)
                answer.set(duration.flatMap { $0.isNumeric ? $0.seconds : nil })
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + thumbnailLengthBudget) == .success else { return .outOfTime }
        guard let seconds = answer.seconds, seconds.isFinite, seconds > 0 else { return .unreadable }
        return .seconds(seconds)
    }
}

/// The frames a bounded request has had back: written on AVFoundation's queue, read once by the waiting queue, then
/// closed, so a late answer is dropped (codex-14 on 1.8.2).
private final class FrameAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private var answered = 0
    private var frames: [CameraController.SampledFrame] = []
    private var closed = false

    init(expected: Int) { self.expected = expected }

    /// Notes one answer; true once every time asked for has one.
    func record(requested: Double, actual: Double, image: CGImage?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        answered += 1
        if let image { frames.append(CameraController.SampledFrame(requested: requested, actual: actual, image: image)) }
        return answered == expected
    }

    /// The frames so far, in the order asked; later answers are dropped.
    func close() -> [CameraController.SampledFrame] {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return frames.sorted { $0.requested < $1.requested }
    }
}

/// The length a detached read hands back to the queue waiting for it, which may have stopped waiting.
private final class ClipLengthAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?

    var seconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ seconds: Double?) {
        lock.lock()
        defer { lock.unlock() }
        value = seconds
    }
}
