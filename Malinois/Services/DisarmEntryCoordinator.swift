//
//  DisarmEntryCoordinator.swift
//  Malinois
//
//  The disarm-entry state machine, extracted from MonitoringEngine (1.3 consolidation,
//  step 7): the owner-attribution candidate window, the "actively entering a PIN" grace, the
//  pad's inactivity timeout and absolute ceiling, and the set of events captured while the
//  pad was open. Two questions this unit answers, kept deliberately separate (F1 / A-02):
//  whether owner-disarm handling MIGHT be in progress (attribution — wide, opens on any
//  touch-down) and whether the owner is ACTIVELY typing right now (presentation suppression —
//  narrow, needs a recent keypress on an open pad). The engine hosts it for the few side
//  effects it cannot do itself (pause the proximity blanking, refresh the screen), mirrors
//  `isActive` into its own @Published property so the PIN pad view is unchanged, and owns
//  what happens to the attributed events (mark + re-exfiltrate) on a successful PIN.
//

import Foundation

/// What the disarm-entry machine needs from the session around it (1.3 step 7).
@MainActor
protocol DisarmEntryHost: AnyObject {
    /// Whether monitoring is still active (armed / triggered) — a timeout that fires after a
    /// disarm must not touch anything.
    var isSessionActive: Bool { get }
    /// Proximity blanks the display when the sensor is covered, which would hide the PIN pad;
    /// pause just that sensor while the pad is open, and restore it (Pro-aware) when it closes.
    func pauseProximityForEntry()
    func resumeProximityAfterEntry()
    /// The pad opened or closed, or the flash/alert suppression changed — repaint the screen.
    func disarmPresentationChanged()
}

@MainActor
final class DisarmEntryCoordinator {
    private let timing: EngineTiming
    weak var host: (any DisarmEntryHost)?

    /// True while the disarm PIN pad is open. The engine mirrors this into its own @Published
    /// property (the view binding is unchanged), so a change is announced through `onActiveChange`.
    private(set) var isActive = false
    var onActiveChange: ((Bool) -> Void)?
    private func setActive(_ value: Bool) {
        guard isActive != value else { return }
        isActive = value
        onActiveChange?(value)
    }

    private var timer: Timer?
    private var startedAt: Date?
    /// When the owner's disarm HOLD began (press-down), before the pad opens 5 s later. The
    /// attribution window opens HERE, not at `begin()` — otherwise the very touch that starts a
    /// legitimate disarm is logged as an un-attributed tamper and pushed to the owner's other
    /// devices (R-02).
    private var candidateSince: Date?
    /// Last keypress on the open pad — evidence that someone is actually entering a PIN rather
    /// than merely holding the pad open (A-02).
    private var lastKeypress: Date?
    /// Events captured while the pad was open (or during the hold that opened it). If a correct
    /// PIN then lands they were the owner's own handling → the engine marks them
    /// owner-attributed; otherwise they stand as evidence.
    private var candidateEventIDs: Set<UUID> = []

    init(timing: EngineTiming) { self.timing = timing }

    // MARK: - The two windows

    /// Whether the owner-attribution candidate window is open (the hold just began, or the pad
    /// is open).
    private var isCandidateActive: Bool {
        candidateSince.map { Date().timeIntervalSince($0) < timing.disarmCandidateWindow } ?? false
    }

    /// Whether owner-disarm handling *might* be in progress — the pad is open, or a hold that
    /// might open it just began. Used ONLY to mark captured events as owner-attribution
    /// candidates (R-02). Deliberately NOT used to gate the alert or the capture flash:
    /// `noteCandidate()` runs on any touch-down, so gating presentation on this let a mere
    /// touch — the defining act of a snoop — hold the response off for the whole window.
    var inFlow: Bool { isActive || isCandidateActive }

    /// Whether the owner appears to be *actively* entering their PIN right now — the pad is
    /// open AND a key was pressed within the grace. This is what suppresses a fresh alert and
    /// the capture flash (A-02), both of which fight the raised pad brightness only while the
    /// owner is genuinely mid-entry.
    var presentationSuppressed: Bool {
        isActive && Self.entryIsActive(lastKeypress: lastKeypress, now: Date(),
                                       grace: timing.disarmActivityGrace)
    }

    /// Pure (unit-tested). Opening the pad is not the same as using it: the pad stays up for
    /// 30 s of inactivity (up to a 120 s ceiling), so gating on mere openness handed anyone
    /// willing to do the 5-second hold 30–150 s of guaranteed silence, renewable indefinitely
    /// by re-holding. Requiring a *recent keypress* keeps F1's actual purpose — don't fight the
    /// owner while they're typing — while an idle open pad alerts normally (A-02).
    nonisolated static func entryIsActive(lastKeypress: Date?, now: Date,
                                          grace: TimeInterval) -> Bool {
        guard let lastKeypress else { return false }
        return now.timeIntervalSince(lastKeypress) < grace
    }

    // MARK: - Transitions (each mirrors an engine method)

    /// The disarm HOLD began (press-down), before the pad opens 5 s later. Opens the
    /// attribution window so the touch that starts the hold — and anything captured during the
    /// 5 s hold — is attributed to the owner if a correct PIN follows.
    func noteCandidate() { candidateSince = Date() }

    /// The hold was released before the pad opened (a tap, not a disarm): close the candidate
    /// window; those events stand as evidence. No-op once the pad is open.
    func cancelCandidate() {
        guard !isActive else { return }
        candidateSince = nil
        candidateEventIDs.removeAll()
    }

    /// The pad opened. Seed the activity clock so the owner gets the same grace reaching for
    /// the first key as between keys — the pad opening is itself a deliberate 5-second act.
    /// (External review 2026-08-23: a deliberate, BOUNDED re-widening of A-02, not the
    /// pad-openness gating A-02 removed — one 20 s window, a logged 5 s hold to enter, not
    /// renewable without another hold, suppressing only the flash and a fresh alert start;
    /// evidence capture and push are never suppressed.)
    func begin() {
        setActive(true)
        lastKeypress = Date()
        host?.pauseProximityForEntry()
        host?.disarmPresentationChanged()
        startedAt = Date()
        scheduleTimeout()
    }

    /// The PIN pad on each digit: reset the inactivity timer so a slow owner (dim screen,
    /// mistype) isn't dropped mid-entry (R-09) — but never past the absolute ceiling, so the
    /// pad still can't be held open forever.
    func noteActivity() {
        guard isActive else { return }
        // Reflects "a key was just pressed" — what suppresses the alert and flash (A-02).
        // Updated even past the ceiling: the ceiling governs the pad's lifetime, not typing.
        lastKeypress = Date()
        if let startedAt, Date().timeIntervalSince(startedAt) > timing.disarmEntryCeiling { return }
        scheduleTimeout()
    }

    /// PIN entry dismissed without a disarm (cancel, or the inactivity timeout): return to
    /// covert/alert. Whatever was captured while the pad was open stands as evidence.
    func end() {
        timer?.invalidate(); timer = nil
        startedAt = nil
        setActive(false)
        lastKeypress = nil
        candidateSince = nil
        candidateEventIDs.removeAll()
        guard host?.isSessionActive == true else { return }
        host?.resumeProximityAfterEntry()
        host?.disarmPresentationChanged()
    }

    /// A capture landed: remember it for attribution if handling might be in progress (R-02).
    func noteCandidateEvent(_ id: UUID) {
        if inFlow { candidateEventIDs.insert(id) }
    }

    /// A correct PIN: the owner. Tear the entry state down and hand back the events captured
    /// while the pad was open, for the engine to mark owner-attributed. Does NOT resume
    /// proximity or repaint — the session is transitioning to `.disarmed`, which the engine
    /// handles. Returns an empty set when there is nothing to attribute.
    func takeOwnerEventsOnDisarm() -> Set<UUID> {
        timer?.invalidate(); timer = nil
        startedAt = nil
        setActive(false)
        lastKeypress = nil
        candidateSince = nil
        defer { candidateEventIDs.removeAll() }
        return candidateEventIDs
    }

    private func scheduleTimeout() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timing.disarmEntryTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.end() }
        }
    }
}
