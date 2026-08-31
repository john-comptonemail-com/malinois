//
//  SirenPlayer.swift
//  Malinois
//
//  Plays a loud alarm for the "Siren" response mode. The waveform is synthesized
//  once at runtime (no bundled audio asset, keeping the "no dependencies" rule),
//  and looped via AVAudioPlayer with the .playback category so it sounds even
//  when the ringer switch is silenced.
//
//  Limitation (F-13): iOS gives no app a way to override the *hardware volume*
//  buttons or force output level up — playback volume is relative to the system
//  media volume, so a thief can turn the siren down with the side buttons. This is
//  unavoidable; the mitigations are elsewhere: the on-screen tamper warning is shown
//  in siren mode regardless of audio (a visual deterrent that can't be muted), and
//  the evidence has already been captured and pushed before the siren even starts —
//  so silencing the alarm doesn't undo any of that. SECURITY.md documents it.
//

import Foundation
import OSLog
import AVFoundation

@MainActor
final class SirenPlayer {

    private var player: AVAudioPlayer?
    private let fileURL: URL
    private var interruptionObserver: NSObjectProtocol?

    /// What the alarm SHOULD be doing, independent of whether the OS has paused our
    /// player. A phone call (or Siri, or another app) posts an audio *interruption* that
    /// stops the `AVAudioPlayer` — and nothing restarts it on its own, so before this a
    /// single incoming call silenced a running siren permanently (no PIN, no physical
    /// access; an ordinary spam call did it by accident). The interruption handler resumes
    /// the alarm when the interruption ends iff this is still set.
    private var shouldBeSounding = false

    init() {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("malinois-siren.wav")
        // (Re)synthesize if missing OR unreadable (e.g. a truncated prior write),
        // so siren mode never fails silently for the life of the temp dir.
        if !Self.isPlayable(fileURL) {
            try? FileManager.default.removeItem(at: fileURL)
            try? Self.synthesize(to: fileURL)
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.handleInterruption(note) }
            }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    private static func isPlayable(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && (try? AVAudioPlayer(contentsOf: url)) != nil
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// True after an activation run exhausted its attempts with the alarm still owed —
    /// the failures-say-so-out-loud hook the engine surfaces on Home after the incident
    /// (eighth-review M5). Cleared the moment playback actually starts.
    private(set) var activationExhausted = false

    /// Consumes the exhaustion flag: reports whether it was set and clears it, so one real
    /// failure is noted exactly once (fourth-pass SR-1 — the flag was only ever cleared by
    /// a later SUCCESSFUL play, so a single exhaustion re-raised the "siren couldn't sound"
    /// notice at the end of every later session in which the siren never sounded, quiet
    /// sessions with no alert included).
    func consumeActivationExhausted() -> Bool {
        defer { activationExhausted = false }
        return activationExhausted
    }

    /// Test-only: latches the exhaustion flag, standing in for an activation run failing
    /// against a held audio session (the real path needs audio contention timed against
    /// activation — not unit-constructible, see BACKLOG 42's device-leg note), so SR-1's
    /// consume-once rule can be regression-tested.
    func setActivationExhaustedForTesting() { activationExhausted = true }

    /// Pure (unit-tested): whether a fresh activation attempt is owed — the alarm should be
    /// sounding and isn't. Extending the alert window is fresh evidence the incident is
    /// live, so exhaustion must not outlast the contention that caused it.
    nonisolated static func reattemptNeeded(shouldBeSounding: Bool, isPlaying: Bool) -> Bool {
        shouldBeSounding && !isPlaying
    }

    /// Re-attempt activation if the alarm should be sounding but isn't (eighth-review M5):
    /// activation can exhaust its ~2.4 s retry budget against a held audio session, and
    /// before this, continued tampering merely extended a SILENT alert window. Full volume,
    /// not a ramp — by the time an extension arrives, the entry-delay window is long gone.
    func ensureSounding() {
        guard Self.reattemptNeeded(shouldBeSounding: shouldBeSounding, isPlaying: isPlaying) else { return }
        beginPlayback(rampUp: false)
    }

    /// Volume the ramped siren opens at — audible enough to be noticed (and to tell the
    /// owner they need to disarm), quiet enough not to be punishing across the hold + PIN.
    static let rampStartVolume: Float = 0.15
    /// How long it stays quiet before rising.
    static let rampHoldSeconds: TimeInterval = 10
    /// How long the rise to full volume takes after the quiet period.
    static let rampFadeSeconds: TimeInterval = 10

    private var rampTimer: Timer?

    /// Starts the alarm.
    ///
    /// - Parameter rampUp: when true, the siren opens quiet, holds for
    ///   `rampHoldSeconds`, then fades to full over `rampFadeSeconds` — the classic
    ///   alarm "entry delay". The owner, whose disarm needs a 5 s hold plus a PIN, hears
    ///   only the quiet phase; anyone who doesn't disarm gets the full alarm. Escalations
    ///   (suspected jamming / sensor flood) call `goFullVolume()` instead: those mean the
    ///   evidence may not escape, so they go loud immediately.
    func start(rampUp: Bool = false) {
        shouldBeSounding = true
        if let p = player, p.isPlaying { return }   // already sounding (incl. mid-ramp) — leave it
        beginPlayback(rampUp: rampUp)
    }

    /// Ensure the alarm is sounding at full volume immediately — for escalations
    /// (jamming / flood) that must be loud NOW. Handles every prior state: not started,
    /// ramping quietly, or stopped by an interruption.
    func goFullVolume() {
        shouldBeSounding = true
        rampTimer?.invalidate(); rampTimer = nil
        if let p = player, p.isPlaying {
            p.setVolume(1.0, fadeDuration: 0)
        } else {
            beginPlayback(rampUp: false)   // not started, or interrupted → (re)start loud
        }
    }

    /// The audio session can be briefly held by something we've just asked to release — the
    /// capture session's microphone (its shutdown is dispatched asynchronously), or a call
    /// that just ended. Rather than leave the alarm silent, retry activation a few times.
    private static let maxActivationAttempts = 6
    private static let activationRetryDelay: TimeInterval = 0.4

    /// (Re)builds the player and starts playback. Tears down any stale player first — after
    /// an interruption the old player object lingers but is stopped, and reusing it would
    /// no-op silently.
    private func beginPlayback(rampUp: Bool, attempt: Int = 1) {
        rampTimer?.invalidate(); rampTimer = nil
        player?.stop(); player = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.duckOthers])
            try session.setActive(true)
            let p = try loadPlayer()
            p.numberOfLoops = -1     // loop until stopped
            p.volume = rampUp ? Self.rampStartVolume : 1.0
            p.prepareToPlay()
            p.play()
            player = p
            activationExhausted = false
            if rampUp { scheduleRamp() }
        } catch {
            guard attempt < Self.maxActivationAttempts, shouldBeSounding else {
                // Exhausted with the alarm still owed (not merely stopped mid-retry):
                // remember it, so the silence is reported instead of just logged (M5).
                if shouldBeSounding { activationExhausted = true }
                // OSStatus 561017449 ('!pri', insufficientPriority) means something else owns
                // the audio session — most often a still-running capture session holding the
                // microphone for clip recording.
                Log.siren.fault("Failed to start the alarm after \(attempt) attempt(s): \(String(describing: error), privacy: .public)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationRetryDelay) { [weak self] in
                Task { @MainActor in
                    guard let self, self.shouldBeSounding, !self.isPlaying else { return }
                    self.beginPlayback(rampUp: rampUp, attempt: attempt + 1)
                }
            }
        }
    }

    private func scheduleRamp() {
        rampTimer?.invalidate()
        rampTimer = Timer.scheduledTimer(withTimeInterval: Self.rampHoldSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                p.setVolume(1.0, fadeDuration: Self.rampFadeSeconds)
                self.rampTimer = nil
            }
        }
    }

    // MARK: - Interruption handling (a phone call must not silence a running siren)

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The OS has already paused our player (a call, Siri, another app). Nothing to
            // do here — we resume on `.ended` if the alarm should still be sounding.
            break
        case .ended:
            // Resume ONLY if we're still supposed to be sounding (not disarmed meanwhile),
            // and ALWAYS at full volume — never re-grant the ramp's quiet window, or a
            // stream of calls could keep the siren perpetually quiet. Deliberately ignores
            // the system's `.shouldResume` hint: a security alarm comes back even when the
            // OS wouldn't auto-resume ordinary media.
            if Self.shouldResumeAfterInterruption(shouldBeSounding: shouldBeSounding) {
                beginPlayback(rampUp: false)
            }
        @unknown default:
            break
        }
    }

    /// Pure (unit-tested). Whether to restart the alarm when an audio interruption ends —
    /// based solely on whether it *should* still be sounding, so a siren the owner already
    /// disarmed never resurrects, and one merely interrupted by a call always returns.
    nonisolated static func shouldResumeAfterInterruption(shouldBeSounding: Bool) -> Bool {
        shouldBeSounding
    }

    /// Loads the looping player, re-synthesizing the waveform if the temp file has
    /// gone missing since init (iOS can purge the temporary directory under storage
    /// pressure) — so siren mode can't silently fail mid-session.
    private func loadPlayer() throws -> AVAudioPlayer {
        if let p = try? AVAudioPlayer(contentsOf: fileURL) { return p }
        try? FileManager.default.removeItem(at: fileURL)
        try Self.synthesize(to: fileURL)
        return try AVAudioPlayer(contentsOf: fileURL)
    }

    func stop() {
        shouldBeSounding = false                     // an interruption ending must NOT revive it
        rampTimer?.invalidate(); rampTimer = nil     // never let a ramp outlive its player
        guard player != nil else { return }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Waveform synthesis

    /// A rising/falling two-tone siren (600↔1200 Hz) as a 16-bit mono WAV.
    private static func synthesize(to url: URL, seconds: Double = 2.0, sampleRate: Double = 44_100) throws {
        let frames = Int(seconds * sampleRate)
        var samples = [Int16](); samples.reserveCapacity(frames)
        var phase = 0.0
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            // Sweep 0…1…0 across the cycle so the loop is seamless-ish.
            let sweep = 0.5 * (1 - cos(2 * .pi * t / seconds))
            let freq = 600 + 600 * sweep
            phase += 2 * .pi * freq / sampleRate
            phase.formTruncatingRemainder(dividingBy: 2 * .pi)   // keep bounded
            let amplitude = 0.9 * sin(phase)
            samples.append(Int16(max(-1, min(1, amplitude)) * Double(Int16.max)))
        }
        try wavData(samples: samples, sampleRate: Int(sampleRate)).write(to: url, options: .atomic)
    }

    private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let dataSize = samples.count * MemoryLayout<Int16>.size
        let byteRate = sampleRate * 2
        func ascii(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)             // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(2); u16(16)
        ascii("data"); u32(UInt32(dataSize))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}
