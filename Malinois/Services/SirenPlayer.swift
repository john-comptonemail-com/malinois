//
//  SirenPlayer.swift
//  Malinois
//
//  Plays a loud alarm for the "Siren" response mode. The waveform is synthesized
//  once at runtime (no bundled audio asset, keeping the "no dependencies" rule),
//  and looped via AVAudioPlayer; it sounds even when the ringer switch is silenced.
//  In Siren mode it plays from this iPhone's speaker whatever is connected (ADR 0062).
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

/// One place the siren's sound goes, as iOS names it: the kind of output and its name, such as "John's AirPods Pro".
/// An alarm that plays anywhere but this iPhone's speaker is logged by it (ADR 0062).
struct SirenOutput: Equatable {
    let port: AVAudioSession.Port
    let name: String
}

@MainActor
final class SirenPlayer {

    /// The audio setting an alarm plays with (1.8.2's step 26, ADR 0062). On the speaker, for Siren mode: the recording
    /// category, the only one iOS lets an app pin to this iPhone's speaker, with `defaultToSpeaker` and none of the
    /// options that would let Bluetooth headphones or AirPlay take the sound; nothing is recorded with it. Otherwise, for
    /// the suspected-attack alarm in Alert and Stealth and as the fallback: the playback category, which plays wherever
    /// the iPhone's sound goes. Either ducks other apps' sound and plays with the ringer switch on silent, and either is
    /// set with the default mode, never the Sound tripwire's measurement mode, which lowers the playback level. Pure
    /// (unit-tested).
    nonisolated static func audioSetting(onSpeaker: Bool) -> (category: AVAudioSession.Category,
                                                              options: AVAudioSession.CategoryOptions) {
        onSpeaker ? (.playAndRecord, [.defaultToSpeaker, .duckOthers]) : (.playback, [.duckOthers])
    }

    /// The first output that is not this iPhone's speaker: where an alarm plays elsewhere; nil when it plays from the
    /// speaker, or when iOS names no output. Pure.
    nonisolated static func elsewhere(outputs: [SirenOutput]) -> SirenOutput? {
        outputs.first { $0.port != .builtInSpeaker }
    }

    /// Told once an alarm, from its start to its stop, when it plays anywhere but this iPhone's speaker without the
    /// speaker setting: the suspected-attack alarm in Alert and Stealth, or Siren mode's when its own setting would not
    /// start. The engine logs it (ADR 0062).
    var onPlayingElsewhere: ((SirenOutput) -> Void)?

    private var player: AVAudioPlayer?
    private let fileURL: URL
    /// Set in `init` and read in `deinit`, never concurrently: `deinit` runs when nothing else
    /// holds the player, and it cannot be main-actor isolated on iOS 17 (item 97).
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?

    /// What the alarm SHOULD be doing, independent of whether the OS has paused our
    /// player. A phone call (or Siri, or another app) posts an audio *interruption* that
    /// stops the `AVAudioPlayer` — and nothing restarts it on its own, so before this a
    /// single incoming call silenced a running siren permanently (no PIN, no physical
    /// access; an ordinary spam call did it by accident). The interruption handler resumes
    /// the alarm when the interruption ends iff this is still set.
    private var shouldBeSounding = false

    /// Whether the siren activated the shared audio session and has not released it since (codex-6 on 0920241): a start
    /// the player refuses, or a player that fails to load, leaves it active with no player kept, and `stop()` releases
    /// it all the same.
    private var sessionActive = false

    /// Whether the alarm is to play from this iPhone's speaker (Siren mode, ADR 0062): set by each request to start it,
    /// and kept for its restarts (an activation retry, a call's end, `ensureSounding`).
    private var onSpeaker = false

    /// Whether the alarm's last start put the speaker setting in place: while it plays, a change of route asks for the
    /// speaker again, since iOS drops that request at every change of route (wired headphones plugged in, say).
    private var playsWithSpeakerSetting = false

    /// Whether this alarm has been reported playing elsewhere: once from its start to its stop.
    private var elsewhereReported = false

    /// Set in `init` and read in `deinit`, as `interruptionObserver` is.
    nonisolated(unsafe) private var routeObserver: NSObjectProtocol?

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
                // Read the type here: a `Notification` does not cross into the main actor (item 97).
                let type = Self.interruptionType(fromUserInfo: note.userInfo)
                Task { @MainActor in self?.handleInterruption(type) }
            }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleRouteChange() }
            }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    private static func isPlayable(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && (try? AVAudioPlayer(contentsOf: url)) != nil
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// True after an activation run exhausted its attempts with the alarm still owed —
    /// the failures-say-so-out-loud hook the engine surfaces on Home after the incident
    /// (eighth-review M5). Cleared the moment playback actually starts: a start the player
    /// refuses counts as a failed attempt (item 167's A3).
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

    #if DEBUG
    /// Test-only (Debug-only, ninth review R2-F2's class): latches the exhaustion flag,
    /// standing in for an activation run failing against a held audio session (the real
    /// path needs audio contention timed against activation — not unit-constructible, see
    /// BACKLOG 42's device-leg note), so SR-1's consume-once rule can be regression-tested.
    func setActivationExhaustedForTesting() { activationExhausted = true }
    /// Test-only: the playing player's volume, nil when none plays.
    var volumeForTesting: Float? { player?.volume }
    /// Test-only (item 162's A1): the level the alarm was last started at, before the test runner's silence.
    private(set) var startLevelForTesting: Float?
    /// Test-only (item 162's A1): the clock the ramp is measured on; the uptime unless a test moves it.
    var uptimeForTesting: (() -> TimeInterval)?
    /// Test-only (codex-4): the next this many activation attempts fail, as against a held audio session.
    var activationFailuresForTesting = 0
    /// Test-only (item 167's A3): the next this many starts answer false, as `AVAudioPlayer.play()` does for a start that
    /// failed without throwing.
    var playFailuresForTesting = 0
    /// Test-only (codex-6 on 0920241): how many times `stop()` asked iOS to release the audio session (a `try?`
    /// deactivation: the count does not show that iOS released it, or that other apps' sound came back up).
    private(set) var sessionReleasesForTesting = 0
    /// Test-only (item 152's lead 6): how many times the alarm was asked to sound (`start`, `goFullVolume`, and
    /// `ensureSounding` when it re-attempts). The test host plays nothing, so `isPlaying` cannot stand in for it.
    private(set) var soundRequestsForTesting = 0
    /// Test-only (item 152's lead 6): stops the player as the capture session's deactivation would, with the alarm
    /// still owed (`shouldBeSounding` stays), so a test can check that a late release makes it sound again.
    func silenceForTesting() { player?.stop() }
    /// Test-only (1.8.2's step 26): the next this many speaker settings fail to start, as one iOS refuses would.
    var speakerSettingFailuresForTesting = 0
    /// Test-only (item 170's codex-7): the next this many speaker requests are refused, as iOS might refuse one.
    var speakerOverrideFailuresForTesting = 0
    /// Test-only (1.8.2's step 26): how many times the speaker was asked for.
    private(set) var speakerOverridesForTesting = 0
    /// Test-only (1.8.2's step 26): where the sound goes, in place of iOS's route.
    var outputsForTesting: [SirenOutput]?

    /// Under the test runner the siren plays at zero volume (owner, 2026-10-13): the suite reaches
    /// the real player (suspected jamming sounds it whatever the response mode), and the Simulator
    /// played it through the Mac's speakers. Its state is unchanged, so what reads it sees a phone's.
    private static let silentUnderTests = TestHost.isTestRunnerLaunch(
        xcTestLoaded: NSClassFromString("XCTestCase") != nil, environment: ProcessInfo.processInfo.environment)
    #endif

    /// `level`, or silence under the test runner (Debug builds only; see `silentUnderTests`).
    private static func audible(_ level: Float) -> Float {
        #if DEBUG
        if silentUnderTests { return 0 }
        #endif
        return level
    }

    /// Pure (unit-tested): whether a fresh activation attempt is owed — the alarm should be
    /// sounding and isn't. Extending the alert window is fresh evidence the incident is
    /// live, so exhaustion must not outlast the contention that caused it.
    nonisolated static func reattemptNeeded(shouldBeSounding: Bool, isPlaying: Bool) -> Bool {
        shouldBeSounding && !isPlaying
    }

    /// Re-attempt activation if the alarm should be sounding but isn't (eighth-review M5):
    /// activation can exhaust its ~2.4 s retry budget against a held audio session, and
    /// before this, continued tampering merely extended a SILENT alert window. Inside a ramp
    /// (the quiet start and the rise) it comes back where the ramp is, so a restart neither
    /// cuts the owner's quiet window short nor starts it again (item 162's A1: the late
    /// microphone release); past the ramp, or with none, at full volume, as before.
    func ensureSounding() {
        guard Self.reattemptNeeded(shouldBeSounding: shouldBeSounding, isPlaying: isPlaying) else { return }
        noteSoundRequest()
        beginPlayback(rampUp: false, rampFrom: rampStartedAt)
    }

    /// Counts a request to sound, for the tests; nothing in Release.
    private func noteSoundRequest() {
        #if DEBUG
        soundRequestsForTesting += 1
        #endif
    }

    /// Volume the ramped siren opens at — audible enough to be noticed (and to tell the
    /// owner they need to disarm), quiet enough not to be punishing across the hold + PIN.
    nonisolated static let rampStartVolume: Float = 0.15
    /// How long it stays quiet before rising.
    nonisolated static let rampHoldSeconds: TimeInterval = 10
    /// How long the rise to full volume takes after the quiet period.
    nonisolated static let rampFadeSeconds: TimeInterval = 10

    private var rampTimer: Timer?
    /// When the current ramp began, on the uptime clock; nil once an escalation, a stop, an interruption's end or a
    /// full-volume start ends it.
    private var rampStartedAt: TimeInterval?
    /// Each request to sound (a start, an escalation, a restart, an interruption's end) and each stop takes the next
    /// number, and an activation retry acts only while its request's number is still the latest: a retry made for an
    /// earlier intent (a ramp's restart) cannot overtake a later one (an escalation's full volume) (codex-4 on 1.8.2).
    private var playbackRequest = 0

    /// The clock the ramp is measured on: the uptime, which a change of the date cannot move.
    private var uptime: TimeInterval {
        #if DEBUG
        if let uptimeForTesting { return uptimeForTesting() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    /// Pure (unit-tested): the ramp's level `seconds` after a ramped start: quiet through the hold, then rising evenly to
    /// full over the fade, as `setVolume(_:fadeDuration:)` rises (item 162's A1).
    nonisolated static func rampLevel(afterSeconds seconds: TimeInterval) -> Float {
        let rising = seconds - rampHoldSeconds
        guard rising > 0 else { return rampStartVolume }
        guard rising < rampFadeSeconds else { return 1 }
        return rampStartVolume + (1 - rampStartVolume) * Float(rising / rampFadeSeconds)
    }

    /// Pure (unit-tested): how far into its ramp a restart is, when the ramp begun at `anchor` is still under way at
    /// `now`; nil with no ramp, or once it is over. A clock read before the anchor counts as the start.
    nonisolated static func rampElapsed(anchor: TimeInterval?, now: TimeInterval) -> TimeInterval? {
        guard let anchor else { return nil }
        let elapsed = max(0, now - anchor)
        return elapsed < rampHoldSeconds + rampFadeSeconds ? elapsed : nil
    }

    /// Starts the alarm.
    ///
    /// - Parameter rampUp: when true, the siren opens quiet, holds for
    ///   `rampHoldSeconds`, then fades to full over `rampFadeSeconds` — the classic
    ///   alarm "entry delay". The owner, whose disarm needs a 5 s hold plus a PIN, hears
    ///   only the quiet phase; anyone who doesn't disarm gets the full alarm. Escalations
    ///   (suspected jamming / sensor flood) call `goFullVolume()` instead: those mean the
    ///   evidence may not escape, so they go loud immediately.
    /// - Parameter onSpeaker: true in Siren mode: the alarm plays from this iPhone's speaker whatever is connected
    ///   (ADR 0062); false keeps the playback setting, which plays wherever the iPhone's sound goes.
    func start(rampUp: Bool = false, onSpeaker: Bool = false) {
        shouldBeSounding = true
        self.onSpeaker = onSpeaker
        noteSoundRequest()
        if let p = player, p.isPlaying { return }   // already sounding (incl. mid-ramp) — leave it
        beginPlayback(rampUp: rampUp)
    }

    /// Ensure the alarm is sounding at full volume immediately — for escalations
    /// (jamming / flood) that must be loud NOW. Handles every prior state: not started,
    /// ramping quietly, or stopped by an interruption. `onSpeaker` as for `start`.
    func goFullVolume(onSpeaker: Bool = false) {
        shouldBeSounding = true
        self.onSpeaker = onSpeaker
        noteSoundRequest()
        rampTimer?.invalidate(); rampTimer = nil
        rampStartedAt = nil   // loud now: a later restart is loud too
        playbackRequest &+= 1   // and no waiting retry of an earlier request starts it otherwise (codex-4)
        if let p = player, p.isPlaying {
            p.setVolume(Self.audible(1.0), fadeDuration: 0)
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
    /// no-op silently. A start `play()` refuses goes the way of a thrown one: retried, then noted for the owner (item
    /// 167's A3). `rampFrom`: when the ramp a restart continues began (item 162's A1). `request`: the request a
    /// retry belongs to; a first attempt takes the next one (codex-4).
    private func beginPlayback(rampUp: Bool, rampFrom anchor: TimeInterval? = nil, attempt: Int = 1,
                               request: Int? = nil) {
        let request = request ?? nextPlaybackRequest()
        rampTimer?.invalidate(); rampTimer = nil
        player?.stop(); player = nil
        do {
            #if DEBUG
            if activationFailuresForTesting > 0 {
                activationFailuresForTesting -= 1
                throw CocoaError(.featureUnsupported)   // stands in for a held audio session
            }
            #endif
            let session = AVAudioSession.sharedInstance()
            let setting = try activate(session)
            sessionActive = true
            let p = try loadPlayer()
            p.numberOfLoops = -1     // loop until stopped
            let now = uptime
            let elapsed = rampUp ? nil : Self.rampElapsed(anchor: anchor, now: now)   // a ramp this restart continues
            let level: Float = rampUp ? Self.rampStartVolume : elapsed.map(Self.rampLevel(afterSeconds:)) ?? 1.0
            #if DEBUG
            startLevelForTesting = level
            #endif
            p.volume = Self.audible(level)
            p.prepareToPlay()
            guard startPlaying(p) else { throw PlaybackRefused() }
            player = p
            activationExhausted = false
            playsWithSpeakerSetting = setting.speaker
            if !setting.granted { reportIfElsewhere() }   // the speaker granted plays from the speaker (ADR 0062)
            if rampUp {
                rampStartedAt = now
                scheduleRamp()
            } else if let elapsed {
                scheduleRamp(after: elapsed)   // the rest of the ramp, from where it was
            } else {
                rampStartedAt = nil
            }
        } catch {
            guard attempt < Self.maxActivationAttempts, shouldBeSounding else {
                // Exhausted with the alarm still owed (not merely stopped mid-retry):
                // remember it, so the silence is reported instead of just logged (M5).
                if shouldBeSounding { activationExhausted = true }
                // OSStatus 561017449 ('!pri', insufficientPriority) means something else owns
                // the audio session — most often a still-running capture session holding the
                // microphone for clip recording.
                Log.siren.fault("Failed to start the alarm after \(attempt) attempt(s): \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationRetryDelay) { [weak self] in
                Task { @MainActor in
                    guard let self, self.playbackRequest == request, self.shouldBeSounding, !self.isPlaying else { return }
                    self.beginPlayback(rampUp: rampUp, rampFrom: anchor, attempt: attempt + 1, request: request)
                }
            }
        }
    }

    /// Starts `player`, answering whether it did: `AVAudioPlayer.play()` answers false for a start that failed without
    /// throwing (item 167's A3).
    private func startPlaying(_ player: AVAudioPlayer) -> Bool {
        #if DEBUG
        if playFailuresForTesting > 0 {
            playFailuresForTesting -= 1
            return false
        }
        #endif
        return player.play()
    }

    /// A start `AVAudioPlayer.play()` refused without throwing (item 167's A3).
    private struct PlaybackRefused: Error {}

    private func nextPlaybackRequest() -> Int {
        playbackRequest &+= 1
        return playbackRequest
    }

    /// Schedules the rest of a ramp `elapsed` seconds in: what is left of the quiet hold, then the rise; or, already in
    /// the rise, what is left of it from the level reached (item 162's A1).
    private func scheduleRamp(after elapsed: TimeInterval = 0) {
        rampTimer?.invalidate()
        let hold = Self.rampHoldSeconds - elapsed
        guard hold > 0 else {
            player?.setVolume(Self.audible(1.0), fadeDuration: Self.rampHoldSeconds + Self.rampFadeSeconds - elapsed)
            rampTimer = nil
            return
        }
        rampTimer = Timer.commonMode(interval: hold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                p.setVolume(Self.audible(1.0), fadeDuration: Self.rampFadeSeconds)
                self.rampTimer = nil
            }
        }
    }

    // MARK: - Where it plays (1.8.2's step 26, ADR 0062)

    /// Puts the alarm's audio setting in place and activates it, answering whether it is the speaker setting and
    /// whether iOS granted the speaker: in Siren mode the speaker one, with the speaker asked for, which also takes the
    /// sound off wired headphones (the setting's option alone does not); if that will not start, the playback one, so
    /// the alarm still sounds. A speaker request iOS refuses is checked like the fallback (item 170's codex-7). Throws
    /// when neither starts, as against a held audio session: the caller retries.
    private func activate(_ session: AVAudioSession) throws -> (speaker: Bool, granted: Bool) {
        if onSpeaker {
            do {
                #if DEBUG
                if speakerSettingFailuresForTesting > 0 {
                    speakerSettingFailuresForTesting -= 1
                    throw CocoaError(.featureUnsupported)   // stands in for a speaker setting iOS will not start
                }
                #endif
                let setting = Self.audioSetting(onSpeaker: true)
                try session.setCategory(setting.category, mode: .default, options: setting.options)
                try session.setActive(true)
                return (true, askForTheSpeaker(session))
            } catch {
                Log.siren.error("The siren's speaker setting did not start; trying the playback one: \(Log.ref(error), privacy: .public)")
            }
        }
        let setting = Self.audioSetting(onSpeaker: false)
        try session.setCategory(setting.category, mode: .default, options: setting.options)
        try session.setActive(true)
        return (false, false)
    }

    /// Asks iOS to play the alarm from this iPhone's speaker whatever is connected, wired headphones included; answers
    /// whether iOS did.
    private func askForTheSpeaker(_ session: AVAudioSession) -> Bool {
        #if DEBUG
        speakerOverridesForTesting += 1
        if speakerOverrideFailuresForTesting > 0 {
            speakerOverrideFailuresForTesting -= 1
            return false   // stands in for a refusal
        }
        #endif
        do {
            try session.overrideOutputAudioPort(.speaker)
            return true
        } catch {
            Log.siren.error("iOS refused the speaker for the siren: \(Log.ref(error), privacy: .public)")
            return false
        }
    }

    /// A device that connects while the alarm plays on the speaker setting (wired headphones, a USB device, a car)
    /// takes the sound, since iOS drops the speaker request at every change of route: ask for the speaker again. Not
    /// while the sound is on the speaker, which also keeps the request's own change of route from asking again, and not
    /// while the player is stopped (a call holding the audio, or the alarm over): a restart asks for it anyway. A
    /// request iOS refuses reports where the siren plays (item 170's codex-7).
    private func handleRouteChange() {
        guard playsWithSpeakerSetting, isPlaying, Self.elsewhere(outputs: currentOutputs()) != nil else { return }
        if !askForTheSpeaker(AVAudioSession.sharedInstance()) { reportIfElsewhere() }
    }

    /// Tells `onPlayingElsewhere` where the alarm plays when that is not this iPhone's speaker, once an alarm.
    private func reportIfElsewhere() {
        guard !elsewhereReported, let away = Self.elsewhere(outputs: currentOutputs()) else { return }
        elsewhereReported = true
        onPlayingElsewhere?(away)
    }

    /// Where the sound goes now, as iOS names it.
    private func currentOutputs() -> [SirenOutput] {
        #if DEBUG
        if let outputsForTesting { return outputsForTesting }
        #endif
        return AVAudioSession.sharedInstance().currentRoute.outputs.map { SirenOutput(port: $0.portType, name: $0.portName) }
    }

    // MARK: - Interruption handling (a phone call must not silence a running siren)

    /// The interruption's type, read from the notification where it arrives.
    nonisolated private static func interruptionType(fromUserInfo userInfo: [AnyHashable: Any]?) -> AVAudioSession.InterruptionType? {
        (userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard let type else { return }
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
                rampStartedAt = nil   // full volume from here, whatever retries or restarts follow (codex-4)
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
        rampStartedAt = nil
        playbackRequest &+= 1                         // and no waiting retry outlives the stop
        elsewhereReported = false                     // the next alarm is reported on its own (ADR 0062)
        guard sessionActive else { return }           // released once, with a player kept or without (codex-6)
        player?.stop()
        player = nil
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #if DEBUG
        sessionReleasesForTesting += 1
        #endif
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
