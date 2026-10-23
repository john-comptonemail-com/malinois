//
//  MonitoringEngine+SirenMicRelease.swift
//  Malinois
//
//  Item 152's lead 6 (item 145 step 15): the siren waits for the camera to release the microphone, but not for ever.
//  `CameraController.dropMicAndWait` resumes only when its block runs on the camera's session queue, which the app
//  treats as able to block (ADR 0038); an unbounded wait left the alarm silent for the rest of the watch. Kept apart
//  from MonitoringEngine.swift, which sits at the lint size limits.
//

import Foundation

extension MonitoringEngine {
    /// Releases the microphone for the siren and waits at most `timing.sirenMicReleaseWait` for it (the session queue
    /// may block, ADR 0038): true when the release landed in time. Late, the release goes on unstructured, and when it
    /// lands the alarm is made to sound again if it should be: the session's deactivation can silence a running player.
    func releaseMicForSiren() async -> Bool {
        let release = Task { @MainActor [camera] in await camera.dropMicAndWait() }
        let inTime = await Self.finishes(release, within: timing.sirenMicReleaseWait)
        if !inTime {
            Log.engine.error("The camera did not release the microphone in \(self.timing.sirenMicReleaseWait, privacy: .public) s; sounding the siren anyway")
            Task { @MainActor [weak self] in
                await release.value
                guard let self, self.alertActive else { return }
                self.siren.ensureSounding()   // the late release may have silenced the alarm
            }
        }
        return inTime
    }

    /// Whether `task` finishes within `seconds`. The loser is abandoned, never cancelled: the release is queued work
    /// that ignores cancellation, as `EvidenceCapturePipeline.withDeadline` explains.
    nonisolated static func finishes(_ task: Task<Void, Never>, within seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let first = FirstToFinish()
            Task { await task.value; if first.claim() { cont.resume(returning: true) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                if first.claim() { cont.resume(returning: false) }
            }
        }
    }
}

/// First-resume-wins latch (the pattern of `EvidenceCapturePipeline`'s deadline): two unstructured tasks share it.
private final class FirstToFinish: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
