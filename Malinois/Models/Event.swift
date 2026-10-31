//
//  Event.swift
//  Malinois
//
//  A single tamper event: what tripped, when, the captured evidence, and
//  short sensor traces for the event window.
//

import Foundation

struct Event: Identifiable, Codable, Equatable, Hashable {
    // Facts fixed at the moment of the tamper.
    let id: UUID
    let startDate: Date
    // Which sensors tripped. `var` only so a coalesced "sustained activity" event can
    // accumulate the sensors seen across a flood; a normal event never mutates it.
    var triggeredSensors: [SensorType]
    // endDate is set once, after capture finishes (see MonitoringEngine.respond).
    var endDate: Date

    /// Filename (relative to the media directory) of the primary evidence —
    /// a still (.jpg) or a clip (.mov).
    var mediaFilename: String?
    /// Optional second capture (used by the "Both" camera option — e.g. the
    /// primary is the front camera and this is the rear).
    var secondaryMediaFilename: String?
    /// A few-KB JPEG thumbnail, kept inline so the log renders without disk I/O
    /// and so the "tiny" CloudKit record has something to carry. For a clip this
    /// is its first frame.
    var thumbnailData: Data?

    /// Which camera each capture used ("front"/"rear") and, for clips, how long
    /// it recorded — surfaced as "F" / "B" durations in the log.
    var primaryCamera: String?
    var primaryDuration: Double?
    var secondaryCamera: String?
    var secondaryDuration: Double?

    /// Accelerometer user-acceleration magnitude samples across the window (g).
    let motionTrace: [Double]
    /// Audio level samples across the window (dBFS, roughly -160…0).
    let audioTrace: [Double]
    /// Vision tripwire samples across the window: fraction of the camera's view that changed
    /// per frame (0…1). Lets a vision trip show WHY it fired even when the photo looks empty.
    /// Optional so events saved before this field decode fine.
    var visionTrace: [Double]?

    var cloudSyncState: CloudSyncState

    /// True if the network was in a total blackout at capture time (a strong
    /// jamming indicator for a stationary armed device). Optional so events saved
    /// before this field decode fine — treat nil as false.
    var capturedOffline: Bool?

    /// For a coalesced "sustained activity" event (sensor flooding), how many trips
    /// it represents. Nil for a normal single-trip event.
    var sustainedCount: Int?

    /// True if this was captured while the disarm PIN pad was open and a correct PIN
    /// then followed — i.e. the owner's own handling, not a tamper. Optional so events
    /// saved before this field decode fine — treat nil as false.
    var ownerAttributed: Bool?

    /// True for a "monitoring interrupted" record: the armed app was killed (force-quit,
    /// Voice Control "Close application", or an OS/OOM crash) without a clean disarm, and
    /// this was logged on the next launch by crash recovery. It carries no camera evidence
    /// (the app was gone), but the *fact* that protection stopped is itself worth recording
    /// and alerting on. Optional so older events decode fine — treat nil as false.
    var interrupted: Bool?

    /// Why an interruption record exists — an `InterruptionCause` raw value — or `nil` when
    /// the launch could not tell (a record from before BACKLOG 53, or a marker with no boot
    /// stamp). Stored as the raw string, like `stateChange`, so a value this build does not
    /// know reads as "unclassified" instead of failing the whole record.
    var interruptionCause: String?

    /// A monitoring state change — `"armed"` or `"disarmed"` — logged so protection turning
    /// on/off is an explicit, auditable record, not something the owner has to infer from
    /// remembering their arm time. Its point is the disarm case: an attacker who knows the
    /// PIN can disarm, but the app has no delete affordance, so the "disarmed" entry stands
    /// as proof of exactly when protection stopped. `nil` for a normal event; carries no
    /// media. Optional so older events decode fine.
    var stateChange: String?

    /// Non-nil when this record was **mirrored from another device** rather than captured
    /// here — the name of the device that captured it.
    ///
    /// Deliberately explicit rather than inferred by comparing `deviceName`, because the
    /// evidence log is the most safety-critical structure in the app and a merge bug that
    /// silently interleaved foreign records with local ones would be very hard to notice.
    /// A mirrored copy is a *claim about another device*, not first-hand evidence captured
    /// here, and the UI says so. `nil` for everything captured locally, which is every event
    /// written before this shipped.
    var sourceDevice: String?

    /// Which generation of this event's cloud record this copy came from — the app's own
    /// monotonic revision, not CloudKit's change tag.
    ///
    /// One event is written to iCloud more than once: a sparse "fact" the instant a tripwire
    /// fires, then the full metadata with its thumbnail and final duration once capture
    /// finishes, then possibly again for owner attribution. Revisions order those writes, so a
    /// stalled early one cannot land last and overwrite a richer later one, and so a mirrored
    /// copy on another device can be replaced by a later revision of itself rather than being
    /// frozen at whatever arrived first. `nil` on events written before this existed.
    var cloudRevision: Int?

    /// True when the storage byte cap discarded this event's media and none remain in iCloud (34.H5, 1.2): either
    /// they never uploaded or a later cloud loss removed the last copies. Pruning synced media is silent while its
    /// cloud copy is believed to remain. A later metadata-only retry carries the loss instead of promising a download.
    /// Set only when no current receipt says any of the capture's files remain in iCloud (`uploadedMedia`, item 166's
    /// codex-23): part of a capture there keeps its download, here and on the other devices. With no
    /// record of a landed file, only once iCloud has been asked and holds none
    /// (`mediaDiscardUnchecked`, codex-24); never at once for a capture whose upload history this
    /// phone cannot know (`CloudEnrollment.uploadHistoryUnknown`, codex-29).
    var mediaDiscarded: Bool?

    /// The byte cap discarded this capture's files with no current record that any remain in iCloud (item 166's
    /// codex-24, the owner's option (b)); also owed when a later cloud loss voids an already-pruned capture's receipts.
    /// An older version keeps no receipts, and a file can land unnoticed (a kill or lost reply). The sweep asks before the
    /// capture is marked lost (`mediaDiscarded`); until then its download is offered, and, as with the
    /// mark, the capture takes no late camera file. Kept on this phone only (no record carries it).
    var mediaDiscardUnchecked: Bool?

    /// The camera files of this phone's own capture that reached iCloud (item 166's codex-23, the
    /// owner's option (a)): each file's camera token, noted as its upload lands, cleared only when
    /// iCloud's copies are found deleted or reset (`receiptEpoch`, item 174's codex-1), so the byte
    /// cap marks the capture lost only when none did. Nil until one lands, and on copies
    /// from other devices; kept on this phone (no record carries the field, though the record's list of
    /// its media names these files too: `mediaManifest`, deepseek-1 on ce4c949).
    var uploadedMedia: [String]?

    /// The generation of this phone's upload receipts (item 174's codex-1): raised when iCloud's copies are found deleted
    /// or reset (`EventStore.requeuedForReupload`), which voids the receipts noted before (`uploadedMedia`), so the byte
    /// cap asks iCloud again before it decides what was lost. Already-pruned captures owe that check too. An older
    /// copy of the event cannot bring receipts back, nor can a
    /// file that an upload started before then reports as landed. Nil until the first such loss; kept on this phone (no
    /// record carries it).
    var receiptEpoch: Int?

    /// Recorded while iCloud backup was off (item 115): it never uploads, even once backup is back
    /// on (the owner's ruling). Set by the store when the event is added; nil otherwise.
    var keptLocal: Bool?

    /// Whether this record could be a missed upload if the event limit removed it: a first-hand
    /// record not fully backed up and not kept on this device by choice, since 1.8.2 status entries
    /// and interruptions as well as incidents (item 169's codex-1). Flood records, other devices'
    /// copies and synced events never count. Whether its account lets it upload is the engine's
    /// question (item 114's marker; the store keeps only these for it, item 116's Q1).
    var mayBeAMissedUpload: Bool {
        !isMirrored && sustainedCount == nil && cloudSyncState != .synced && keptLocal != true
    }

    /// Why this event has no capture — or why its first capture failed before the one
    /// bounded retry attached a photo (item 54): a `CaptureFailureReason` raw value,
    /// allow-listed on the way in from the cloud. `nil` when the capture worked, or the
    /// camera tripwire was off.
    var captureFailure: String?
    /// Original camera coverage failures or saved-clip issues, keyed by front/rear.
    /// Historical: a later retry or download never clears these reasons. Optional for old events;
    /// cloud input permits only the two camera names and known CaptureFailureReason values.
    var captureFailuresByCamera: [String: String]?

    /// Records a saved clip's partial/unverified outcome without hiding surviving evidence.
    mutating func recordCaptureIssue(_ issue: CaptureFailureReason?, camera: String) {
        guard let issue else { return }
        var issues = captureFailuresByCamera ?? [:]
        issues[camera] = issue.rawValue
        captureFailuresByCamera = issues
    }

    /// Fixed-order coverage notices, plus the existing whole-capture failure/retry explanation.
    /// A surviving camera is original evidence; only interruption recovery can label a retry.
    var captureFailureMessages: [String] {
        var messages = ["front", "rear"].compactMap { camera -> String? in
            guard let raw = captureFailuresByCamera?[camera],
                  let reason = CaptureFailureReason(rawValue: raw) else { return nil }
            let label = camera == "front" ? "Front" : "Rear"
            return "\(label) camera, original capture: \(reason.summary)."
        }
        let hasMedia = mediaFilename != nil || secondaryMediaFilename != nil || thumbnailData != nil
            || !(cloudMediaManifest ?? []).isEmpty
        if let why = captureFailureSummary, messages.isEmpty || hasMedia {
            if !hasMedia {
                messages.append("No photo or clip - \(why).")
            } else if captureFailure.flatMap(CaptureFailureReason.init(rawValue:))?.isInterruption == true {
                messages.append("The first capture failed - \(why). This photo was taken when the camera came back.")
            } else {
                messages.append("Capture issue - \(why). Saved evidence is available.")
            }
        }
        return messages
    }

    /// For a MIRRORED event: which camera tokens the capturing device says it uploaded
    /// full-media records under (the payload's manifest, 34's metadataJSON item + B1's
    /// robustness note). Retrieval then fetches exactly what exists instead of probing every
    /// slot blindly. `nil` on local events and on mirrors of records from before the
    /// manifest existed — the blind probe remains the fallback. Optional so older saved
    /// events decode fine.
    var cloudMediaManifest: [String]?

    /// How many wrong disarm PINs this record holds (item 49): 1 on the record a wrong PIN on
    /// the armed screen's pad minted, more when further attempts landed while its capture ran;
    /// on any other record, the attempts that landed during ITS capture. `nil` on every record
    /// without one. The typing itself rides the record as a Touch trip (`triggeredSensors`
    /// holds `.touch`), so a build that predates this field reads the record as a Touch row.
    /// Optional so older saved events decode fine.
    var wrongPINCount: Int?

    /// On a cancelled countdown's record, how many countdowns were cancelled in a row on it, with no watch live between
    /// and none more than ten minutes after the one before (item 169's codex-1); nil for one. Kept on this phone: the
    /// record iCloud holds says the first. Optional so older saved events decode fine.
    var cancelCount: Int?

    /// iOS's thermal state when the record was made, as `MonitoringEngine.thermalStateName`
    /// spells it ("nominal", "fair", "serious", "critical"; item 38, the owner's choice 3):
    /// context for a clip that stops early or a phone that went dark. `nil` on records from
    /// before 1.4 and on audit rows. Optional so older saved events decode fine.
    var thermalState: String?

    /// Whether this event came from another device via iCloud rather than this device's own
    /// sensors. Only ever true for merged copies.
    var isMirrored: Bool { sourceDevice != nil }

    /// Whether this event's full capture can be in iCloud, so that "Download full evidence from
    /// iCloud" can find something (item 118): something was captured (a photo or clip, its thumbnail,
    /// either camera it used, or another device's list of the media it uploaded), and it was uploaded,
    /// by another device (a mirrored copy) or by this iPhone (synced, or a file of it this iPhone knows
    /// landed though the rest did not: `uploadedMedia`, item 166's codex-25). Not after a capture that
    /// never happened (the camera could not start, the camera tripwire was off), and not for this
    /// iPhone's events that never uploaded (no verified account, iCloud backup off), where a tap could
    /// only end in "Nothing came back".
    var fullCaptureMayBeInICloud: Bool {
        let captured = mediaFilename != nil || secondaryMediaFilename != nil || thumbnailData != nil
            || primaryCamera != nil || secondaryCamera != nil   // a Both capture's rear photo alone (Codex's V2)
            || !(cloudMediaManifest ?? []).isEmpty
        return captured && (isMirrored || cloudSyncState == .synced || !(uploadedMedia ?? []).isEmpty
                            || mediaDiscardUnchecked == true)   // iCloud not yet asked (codex-24)
    }

    /// The sentence Share sends with this event (item 124's F15): a status entry or an interruption
    /// record is a log entry, in the owner's words (2026-10-17); a tamper event says what triggered,
    /// and how long its clip ran.
    func shareSentence(timestamp: String) -> String {
        if isStateChange || interrupted == true {
            return "Malinois log entry on \(timestamp): \(sensorSummary)."
        }
        var text = "Malinois detected tampering on \(timestamp) - \(shareClause)."
        if !durationSummary.isEmpty { text += " Recording: \(durationSummary)." }
        return text
    }

    /// The capture failure in the owner's words (item 54); nil when there was none, or the
    /// raw value is one this build does not know.
    var captureFailureSummary: String? {
        captureFailure.flatMap(CaptureFailureReason.init(rawValue:))?.summary
    }

    init(id: UUID = UUID(),
         startDate: Date,
         endDate: Date,
         triggeredSensors: [SensorType],
         mediaFilename: String? = nil,
         secondaryMediaFilename: String? = nil,
         thumbnailData: Data? = nil,
         primaryCamera: String? = nil,
         primaryDuration: Double? = nil,
         secondaryCamera: String? = nil,
         secondaryDuration: Double? = nil,
         motionTrace: [Double] = [],
         audioTrace: [Double] = [],
         visionTrace: [Double]? = nil,
         cloudSyncState: CloudSyncState = .pending,
         capturedOffline: Bool? = nil,
         sustainedCount: Int? = nil,
         ownerAttributed: Bool? = nil,
         interrupted: Bool? = nil,
         interruptionCause: String? = nil,
         stateChange: String? = nil,
         sourceDevice: String? = nil,
         cloudRevision: Int? = nil,
         mediaDiscarded: Bool? = nil,
         captureFailure: String? = nil,
         captureFailuresByCamera: [String: String]? = nil,
         cloudMediaManifest: [String]? = nil,
         wrongPINCount: Int? = nil,
         thermalState: String? = nil) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.triggeredSensors = triggeredSensors
        self.mediaFilename = mediaFilename
        self.secondaryMediaFilename = secondaryMediaFilename
        self.thumbnailData = thumbnailData
        self.primaryCamera = primaryCamera
        self.primaryDuration = primaryDuration
        self.secondaryCamera = secondaryCamera
        self.secondaryDuration = secondaryDuration
        self.motionTrace = motionTrace
        self.audioTrace = audioTrace
        self.visionTrace = visionTrace
        self.cloudSyncState = cloudSyncState
        self.capturedOffline = capturedOffline
        self.sustainedCount = sustainedCount
        self.ownerAttributed = ownerAttributed
        self.interrupted = interrupted
        self.interruptionCause = interruptionCause
        self.stateChange = stateChange
        self.sourceDevice = sourceDevice
        self.cloudRevision = cloudRevision
        self.mediaDiscarded = mediaDiscarded
        self.captureFailure = captureFailure
        self.captureFailuresByCamera = captureFailuresByCamera
        self.cloudMediaManifest = cloudMediaManifest
        self.wrongPINCount = wrongPINCount
        self.thermalState = thermalState
    }

    /// The camera token each full-media upload names its record with — "front"/"rear", with
    /// "primary"/"secondary" as the uploader's fallback when no camera was recorded. Shared
    /// between the exfiltrator's record names and the payload's manifest so the two can
    /// never disagree (the one-value-two-readers lesson this codebase keeps re-learning).
    var primaryMediaToken: String { primaryCamera ?? "primary" }
    var secondaryMediaToken: String { secondaryCamera ?? "secondary" }

    /// The full-media record names a download asks iCloud for (1.8.2's step 32, item 152's lead 10). A copy from
    /// another device: the names its record lists, or every name (nil) when it lists none. This iPhone's own record:
    /// only the cameras it names, the names its own upload gave their captures (every capture this app has stored
    /// since its first build names its camera), so none for a record that names no camera, which has none in iCloud.
    /// A capture another writer saved under any other name cannot join this iPhone's record or give it a camera.
    var downloadManifest: [String]? {
        guard !isMirrored else { return cloudMediaManifest }
        var cameras: [String] = []
        for camera in [primaryCamera, secondaryCamera].compactMap({ $0 }) where !cameras.contains(camera) {
            cameras.append(camera)
        }
        return cameras
    }

    /// Whether the record names a file this iPhone does not hold (item 167's A2): each name a download asks for
    /// (`downloadManifest`) matched to the file it stands for (`holdsFile(named:)`), so another camera's file never
    /// stands in for it (codex-7 on 073e5d2). A camera whose capture failed names none. A record holds two files at
    /// most: with both here, a download can add nothing more, whatever it names. Keeps "Download full evidence from
    /// iCloud" offered, on every visit, after a download that brought one camera's file of two, until the other is here
    /// too. False when the record names none.
    var namesMediaNotHeldHere: Bool {
        guard let names = downloadManifest, !names.isEmpty else { return false }
        guard mediaFilename == nil || secondaryMediaFilename == nil else { return false }   // both slots full
        return names.contains { !holdsFile(named: $0) }
    }

    /// Whether the file a download names `token` is here (codex-7 on 073e5d2): a camera's in the slot labelled with that
    /// camera, as a download places it (`MonitoringEngine.mediaPlacement`); a legacy position's ("primary", "secondary")
    /// in that position. A camera no slot is labelled with has no file here.
    private func holdsFile(named token: String) -> Bool {
        switch token {
        case "primary": return mediaFilename != nil
        case "secondary": return secondaryMediaFilename != nil
        default:
            if primaryCamera == token { return mediaFilename != nil }
            if secondaryCamera == token { return secondaryMediaFilename != nil }
            return false
        }
    }

    /// Whether a download could bring a file of the capture this iPhone does not hold (codex-5 on 0920241): by the names
    /// a download asks for when the record has them (`namesMediaNotHeldHere`), so a capture whose only file is its
    /// second (its front failed) offers nothing once that file is here; for a copy from a version before the list of
    /// uploaded media, which names none, while its first file is not here, as before.
    var mayLackAFileHere: Bool {
        downloadManifest == nil ? mediaFilename == nil : namesMediaNotHeldHere
    }

    /// Which full-media records this event's record names, each once: the payload's manifest (34's metadataJSON item +
    /// B1's robustness note). The files held here, and those this phone knows reached iCloud (`uploadedMedia`), so a file
    /// the storage limit removed after it landed stays named, and another device, or this iPhone reinstalled, can still
    /// ask iCloud for it (DeepSeek's deepseek-1 on ce4c949, the owner's option 1). A capture uploaded before 1.8.2 has no
    /// such record of what landed: for it, the files held. Empty when the event carries none.
    var mediaManifest: [String] {
        var tokens: [String] = []
        if mediaFilename != nil { tokens.append(primaryMediaToken) }
        if secondaryMediaFilename != nil { tokens.append(secondaryMediaToken) }
        for token in uploadedMedia ?? [] where !tokens.contains(token) { tokens.append(token) }
        return tokens
    }

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    /// Recording duration(s) labeled by camera — "F 5.0s", "B 5.0s", or both for
    /// the "Both" option. Empty for stills (no meaningful clip length).
    var durationSummary: String {
        func label(_ camera: String?) -> String { camera == "rear" ? "B" : "F" }
        var parts: [String] = []
        if let d = primaryDuration { parts.append("\(label(primaryCamera)) \(String(format: "%.1fs", d))") }
        if let d = secondaryDuration { parts.append("\(label(secondaryCamera)) \(String(format: "%.1fs", d))") }
        return parts.joined(separator: " · ")
    }

    /// The detail screen's words for `thermalState` (item 38): plain, and saying what iOS does
    /// at each level. Screen text, so no em-dashes.
    var thermalStateSummary: String? {
        switch thermalState {
        case "nominal":  return "Normal"
        case "fair":     return "Slightly warm"
        case "serious":  return "Hot: iOS is slowing the phone"
        case "critical": return "Overheating: iOS may shut the phone down"
        default:         return nil
        }
    }

    /// A monitoring state-change record (armed / disarmed) carries no sensor evidence and is
    /// rendered differently in the log (no media, no sync badge).
    var isStateChange: Bool { stateChange != nil }

    /// The existing sensorless interference diagnostic, distinct from lifecycle/status
    /// and wrong-PIN records. It reports an alarm already raised; its upload cannot itself
    /// justify another alarm. Computed from existing fields, including older cloud copies.
    var isSignalLoss: Bool {
        triggeredSensors.isEmpty && !isStateChange && interrupted != true && (wrongPINCount ?? 0) == 0
    }

    var sensorSummary: String {
        switch stateChange {
        case "armed":    return "Monitoring armed"
        case "disarmed": return "Monitoring disarmed"
        case "gaLifted": return "Guided Access requirement lifted for one arm"
        case "cameraError": return "Camera session failed while armed"
        case "armingCancelled":   // a run of them counts on one record (item 169's codex-1)
            if let count = cancelCount, count > 1 { return "Arming cancelled before going live, \(count) times in a row" }
            return "Arming cancelled before going live"
        case "armingInterrupted": return "Arming did not complete: the app ended during the countdown"
        case "thermalSerious":    return "Phone running hot while armed"                         // item 38
        case "thermalCritical":   return "Phone overheating while armed: iOS may shut it down"
        case "soundUnavailable":  return "Sound tripwire unavailable while armed: the microphone could not be restarted"   // item 105, F-09
        case "soundRestored":     return "Sound tripwire working again"
        case "motionStalled":     return "Motion tripwire stalled and was restarted: a few seconds were not watched"   // item 144 (g)
        case "reinstalled":       return "Malinois was reinstalled on this iPhone: the log it kept before is gone"   // item 148's 5
        case "pinChanged":        return "Malinois PIN changed in Settings; the current PIN was entered first"   // item 153's MAL-03
        case "guidedAccessEnded": return "Guided Access ended while armed; the watch kept running"   // item 153's MAL-05; item 155's A7
        case "unsyncedRemoved":   return "Events not fully backed up to iCloud were removed to make room (log full)"   // items 114, 116
        case "reArmSkipped":      return "Not re-armed automatically: Malinois was closed again within 90 seconds of re-arming itself"   // item 153's MAL-10
        case "settingsReset":     return "Settings couldn't be read and were reset to their defaults"   // codex-10
        case "backupOff":         return "iCloud backup turned off: events recorded while it is off are never uploaded"   // item 115; item 168's deepseek-2
        case "backupOn":          return "iCloud backup turned on"
        default:         break
        }
        if let kind = stateChange, let words = Self.protectionChangeSummary(kind: kind) { return words }
        if let kind = stateChange, let words = Self.clockChangeSummary(kind: kind) { return words }   // item 113
        if let kind = stateChange, let words = Self.resumedSummary(kind: kind) { return words }   // item 153's MAL-06
        if let kind = stateChange, let words = Self.sirenElsewhereSummary(kind: kind) { return words }   // 1.8.2's step 26
        // A status entry this build does not know (a newer build's kind, or a damaged log) is
        // never "Signal loss", which asserts an attack. The cloud decoder already drops unknown
        // kinds; this covers the local log (item 105, F-09).
        if stateChange != nil { return "Status entry this version of Malinois does not recognize" }
        if interrupted == true {
            // BACKLOG 53: say what the launch could tell; a cause this build does not know,
            // or none at all (older records, a marker with no stamp), keeps the bare sentence.
            switch interruptionCause.flatMap(InterruptionCause.init(rawValue:)) {
            case .rebooted:     return "Monitoring interrupted: the device restarted while armed"
            case .terminated:   return "Monitoring interrupted: the app was closed or crashed while armed"
            case .backgrounded: return "Monitoring interrupted: the app was sent to the background while armed"
            case .locked:       // the usual way out under Guided Access, not the only one (item 153's MAL-06)
                return "Monitoring interrupted: the device was locked, or Malinois otherwise left the screen, while armed"
            case .backgroundedDuringCountdown:
                return "Monitoring interrupted: the app was sent to the background during the countdown"
            case nil:           return "Monitoring interrupted: the app closed before a clean disarm"
            }
        }
        // A sensorless event is a connectivity-blackout ("possible jamming") capture.
        var base = triggeredSensors.isEmpty ? "Signal loss"
            : triggeredSensors.map { $0.displayName }.joined(separator: ", ")
        if let attempts = wrongPINCount, attempts > 0 {
            base = Self.wrongPINSummary(attempts: attempts,
                                        otherSensors: triggeredSensors.filter { $0 != .touch })
        }
        if let n = sustainedCount, n > 1 { return "\(base), sustained ×\(n)" }
        return base
    }

    // MARK: - Clock changes (item 113)

    /// The status kind for a clock jump seen during a watch (item 113): "clockChanged.8040" for a
    /// clock moved forward 2 h 14 min, "clockChanged.-180" for one moved back 3 min. The jump rides
    /// in the kind, so the cloud record needs no new field.
    static func clockChangeKind(seconds: Int) -> String { "clockChanged." + String(seconds) }

    /// The jump a clock-change kind records; nil for any other kind, a malformed one, no jump, or
    /// one beyond a century. The bound uses the magnitude, which cannot trap: `abs` of the
    /// smallest Int does, and a damaged record from iCloud or the log can hold it (item 116, R10).
    /// Only the number as `clockChangeKind` writes it (1.8.2's step 32): padded with zeros or
    /// signed with a plus it reads as the same number, so a record could carry a megabyte of zeros.
    static func clockChangeSeconds(kind: String) -> Int? {
        let prefix = "clockChanged."
        let digits = kind.dropFirst(prefix.count)
        guard kind.hasPrefix(prefix), let seconds = Int(digits), String(seconds) == digits,
              seconds != 0, seconds.magnitude <= 100 * 365 * 86_400 else { return nil }
        return seconds
    }

    /// "Device clock moved forward 2 h 14 min while armed"; nil unless `kind` is a clock change.
    static func clockChangeSummary(kind: String) -> String? {
        guard let seconds = clockChangeSeconds(kind: kind) else { return nil }
        return "Device clock moved \(seconds > 0 ? "forward" : "back") \(clockJumpWords(abs(seconds))) while armed"
    }

    /// A jump in at most two units: "3 min", "2 h 14 min", "1 d 1 h".
    static func clockJumpWords(_ seconds: Int) -> String {
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        return "\(max(minutes, 1)) min"
    }

    // MARK: - A watch resumed after a lapse (item 153's MAL-06)

    /// The status kind for a live watch back on screen after a lapse: "resumed.252" for 4 min 12 s not watched. The
    /// length rides in the kind, as a clock change's does, so the cloud record needs no new field.
    static func resumedKind(seconds: Int) -> String { "resumed." + String(max(1, seconds)) }

    /// The lapse a resumed kind records, in seconds; nil for any other kind, a malformed one, or one beyond a century
    /// (a damaged record from iCloud or the log). Only the number as `resumedKind` writes it, as for a clock change.
    static func resumedSeconds(kind: String) -> Int? {
        let prefix = "resumed."
        let digits = kind.dropFirst(prefix.count)
        guard kind.hasPrefix(prefix), let seconds = Int(digits), String(seconds) == digits,
              seconds > 0, seconds <= 100 * 365 * 86_400 else { return nil }
        return seconds
    }

    /// The canonical form of a clock-change or resume kind written with its number padded, by zeros or a plus sign,
    /// which an older version's decoder read as the same number (codex-13 on 1.8.2: a copy it saved kept the padding);
    /// any other kind is returned as it is.
    static func canonicalStatusKind(_ kind: String) -> String {
        let clock = "clockChanged.", resume = "resumed."
        if kind.hasPrefix(clock), clockChangeSeconds(kind: kind) == nil, let seconds = Int(kind.dropFirst(clock.count)),
           seconds != 0, seconds.magnitude <= 100 * 365 * 86_400 {
            return clockChangeKind(seconds: seconds)
        }
        if kind.hasPrefix(resume), resumedSeconds(kind: kind) == nil, let seconds = Int(kind.dropFirst(resume.count)),
           seconds > 0, seconds <= 100 * 365 * 86_400 {
            return resumedKind(seconds: seconds)
        }
        return kind
    }

    /// "Monitoring resumed after 4 min 12 s not watched"; nil unless `kind` is a resume.
    static func resumedSummary(kind: String) -> String? {
        guard let seconds = resumedSeconds(kind: kind) else { return nil }
        return "Monitoring resumed after \(lapseWords(seconds)) not watched"
    }

    /// A lapse to the second under an hour ("45 s", "4 min 12 s"), then as a clock jump reads ("2 h 14 min").
    static func lapseWords(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        guard seconds < 3_600 else { return clockJumpWords(seconds) }
        let minutes = seconds / 60, rest = seconds % 60
        return rest > 0 ? "\(minutes) min \(rest) s" : "\(minutes) min"
    }

    // MARK: - The siren played away from this iPhone's speaker (1.8.2's step 26; ADR 0062)

    private static let sirenElsewherePrefix = "sirenElsewhere."

    /// The status kind for an alarm that played through `device`, the name iOS gives the output, kept as
    /// `sirenOutputName` keeps it: "sirenElsewhere.Owner's AirPods Pro".
    static func sirenElsewhereKind(device: String) -> String { sirenElsewherePrefix + sirenOutputName(device) }

    /// An output's name as the log keeps it, as a device label is kept: no whitespace at either end, no control or
    /// direction characters, at most 40 characters and 160 bytes; empty when iOS gave none. It rides inside the entry's
    /// kind, through iCloud too, so it is bounded here.
    static func sirenOutputName(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var kept = "", bytes = 0
        for character in String(String.UnicodeScalarView(scalars)).prefix(40) {
            bytes += character.utf8.count
            guard bytes <= 160 else { break }
            kept.append(character)
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The device a siren-elsewhere kind names, "" when iOS gave none; nil for any other kind, or one whose name is not
    /// as `sirenElsewhereKind` writes it (a damaged record from iCloud or the log).
    static func sirenElsewhereDevice(kind: String) -> String? {
        guard kind.hasPrefix(sirenElsewherePrefix) else { return nil }
        let name = String(kind.dropFirst(sirenElsewherePrefix.count))
        return sirenOutputName(name) == name ? name : nil
    }

    /// "The siren played through Owner's AirPods Pro, not this iPhone's speaker"; nil unless `kind` is a siren-elsewhere
    /// kind.
    static func sirenElsewhereSummary(kind: String) -> String? {
        guard let device = sirenElsewhereDevice(kind: kind) else { return nil }
        return "The siren played through \(device.isEmpty ? "headphones or another device" : device), not this iPhone's speaker"
    }

    // MARK: - iCloud backup (item 115)

    /// The status entry written just before backup turns off; the one record that still uploads.
    static let backupOffKind = "backupOff"
    /// The status entry written when backup turns back on.
    static let backupOnKind = "backupOn"

    // MARK: - Protection settings changes (item 91)

    /// The audit kind that records one protection setting switched off or on (item 91):
    /// "settingOff.camera", "settingOn.requireGuidedAccess".
    static func protectionChangeKind(_ setting: String, on: Bool) -> String {
        (on ? "settingOn." : "settingOff.") + setting
    }

    /// The audit kind that records a setting set to a value (1.8.2's step 22; item 153's MAL-09):
    /// "settingSet.responseMode.stealth", "settingSet.gracePeriod.60", "settingSet.sensitivity.motion.low".
    static func settingValueKind(_ setting: String, _ value: String) -> String {
        "settingSet.\(setting).\(value)"
    }

    /// The protection settings a change record can name switched off or on: the switchable
    /// tripwires, by their stored names, and four settings by name (Face ID unlock since 1.8.2).
    static let protectionSettingNames: [String] = SensorType.allCases.filter { $0 != .touch }.map(\.rawValue)
        + ["requireGuidedAccess", "otherDeviceAlerts", "jammingResponse", "biometricUnlock"]

    /// Every switched kind, and every value kind of the settings with a fixed set of values (the grace period's are
    /// numbers: `isProtectionChangeKind` reads those).
    static let protectionChangeKinds: Set<String> = {
        var kinds = Set(protectionSettingNames.flatMap {
            [protectionChangeKind($0, on: false), protectionChangeKind($0, on: true)]
        })
        kinds.formUnion(ResponseMode.allCases.map { settingValueKind("responseMode", $0.rawValue) })
        for tripwire in SensorType.sensitivityTripwires {
            kinds.formUnion(Sensitivity.allCases.map { settingValueKind("sensitivity." + tripwire.rawValue, $0.rawValue) })
        }
        kinds.formUnion(CameraReadiness.allCases.map { settingValueKind("cameraReadiness", $0.rawValue) })
        kinds.formUnion(IlluminationMode.allCases.map { settingValueKind("illumination", $0.rawValue) })
        kinds.formUnion(CloudRetention.allCases.map { settingValueKind("cloudRetention", $0.rawValue) })
        return kinds
    }()

    /// Whether `kind` is a settings change record (item 91; 1.8.2's step 22): the iCloud decoder's allow-list, and the
    /// log's icon, read it. A malformed or unknown one is not.
    static func isProtectionChangeKind(_ kind: String) -> Bool { protectionChangeSummary(kind: kind) != nil }

    /// Pure (unit-tested): the log's words for a change record, or nil for any other kind.
    static func protectionChangeSummary(kind: String) -> String? {
        if kind.hasPrefix("settingSet.") { return settingValueSummary(kind: kind) }
        guard protectionChangeKinds.contains(kind) else { return nil }
        let on = kind.hasPrefix("settingOn.")
        let name = String(kind.drop { $0 != "." }.dropFirst())
        let state = on ? "on" : "off"
        switch name {
        case "requireGuidedAccess":
            return on ? "Guided Access required again, in Settings" : "Guided Access no longer required, in Settings"
        case "otherDeviceAlerts": return "Alerts to your other devices switched \(state) in Settings"
        case "jammingResponse":   return "Jamming response switched \(state) in Settings"
        // Off without "in Settings": it also switches off by itself when the enrolled faces or fingers change (ADR 0056).
        case "biometricUnlock":
            return on ? "Face ID or Touch ID unlock switched on in Settings" : "Face ID or Touch ID unlock switched off"
        case SensorType.camera.rawValue: return "Camera switched \(state) in Settings"
        default:
            guard let tripwire = SensorType(rawValue: name) else { return nil }
            return "\(tripwire.displayName) tripwire switched \(state) in Settings"
        }
    }

    /// The words for a setting set to a value (1.8.2's step 22), or nil for a malformed kind or value: a sensitivity
    /// only where Settings offers one, a grace period only as a whole number of seconds up to an hour.
    private static func settingValueSummary(kind: String) -> String? {
        let parts = kind.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let value = parts.last else { return nil }
        switch (parts[1], parts.count) {
        case ("responseMode", 3):
            return ResponseMode(rawValue: value).map { "Response mode set to \($0.displayName) in Settings" }
        case ("sensitivity", 4):
            guard let tripwire = SensorType(rawValue: parts[2]), SensorType.sensitivityTripwires.contains(tripwire),
                  let level = Sensitivity(rawValue: value) else { return nil }
            return "\(tripwire.displayName) sensitivity set to \(level.displayName) in Settings"
        case ("gracePeriod", 3):
            guard let seconds = Int(value), String(seconds) == value, (0...3_600).contains(seconds) else { return nil }
            return "Arming grace period set to \(seconds) s in Settings"
        case ("cameraReadiness", 3):
            return CameraReadiness(rawValue: value).map { "Camera battery mode set to \($0.displayName) in Settings" }
        case ("illumination", 3):
            return IlluminationMode(rawValue: value).map { "Illumination set to \($0.displayName) in Settings" }
        case ("cloudRetention", 3):
            return CloudRetention(rawValue: value).map { "iCloud photo and video storage set to \($0.displayName) in Settings" }
        default:
            return nil
        }
    }

    /// Pure (unit-tested): how a record carrying wrong disarm PINs reads (item 49). The typing
    /// is the record's Touch, so the attempt names the record instead; any other tripwire on it
    /// fired first (the attempt joined that trip's capture) and is named first.
    static func wrongPINSummary(attempts: Int, otherSensors: [SensorType]) -> String {
        let times = attempts == 1 ? "" : " \(attempts) times"
        guard !otherSensors.isEmpty else { return "Wrong PIN entered" + times }
        return otherSensors.map { $0.displayName }.joined(separator: ", ") + ", wrong PIN entered" + times
    }

    /// What the share sheet's sentence says happened ("… detected tampering on <date> -
    /// <clause>."): "<tripwires> triggered", except on a record carrying a wrong PIN, which
    /// names the attempt instead (item 49) — an attempt is not something that "triggered".
    var shareClause: String {
        (wrongPINCount ?? 0) > 0 ? sensorSummary : "\(sensorSummary) triggered"
    }

    /// Compact metadata dictionary pushed as JSON in the first (tiny) CloudKit
    /// record so the essential facts land before the full photo uploads.
    ///
    /// Payload v2 (34's metadataJSON item): the fields a mirror used to LOSE — the
    /// sustained-flood count, which camera(s) captured, clip durations, the pre-upload
    /// discard marker — plus the media manifest (B1's robustness note: which full-media
    /// records exist, so retrieval fetches exactly those). All conditional, so the
    /// pre-capture fact stays as tiny as ever; absent keys are how v1 records read too, and
    /// the decoder tolerates both directions by construction.
    var metadataJSON: Data? {
        var payload: [String: Any] = [
            "v": 2,
            "id": id.uuidString,
            "startDate": ISO8601DateFormatter().string(from: startDate),
            "endDate": ISO8601DateFormatter().string(from: endDate),
            "durationSeconds": duration,
            "triggeredSensors": triggeredSensors.map { $0.rawValue },
            "motionPeak": motionTrace.max() ?? 0,
            "audioPeak": audioTrace.max() ?? -160,
            "visionPeak": visionTrace?.max() ?? 0,
            "deviceName": DeviceInfo.name,
            "capturedOffline": capturedOffline ?? false,
            "ownerAttributed": ownerAttributed ?? false,
            "interrupted": interrupted ?? false
        ]
        if let n = sustainedCount { payload["sustainedCount"] = n }
        if let n = wrongPINCount, n > 0 { payload["wrongPINCount"] = n }   // item 49
        if let thermal = thermalState { payload["thermalState"] = thermal }   // item 38, choice 3
        if let cause = interruptionCause { payload["interruptionCause"] = cause }
        if let camera = primaryCamera { payload["primaryCamera"] = camera }
        if let d = primaryDuration { payload["primaryDuration"] = d }
        if let camera = secondaryCamera { payload["secondaryCamera"] = camera }
        if let d = secondaryDuration { payload["secondaryDuration"] = d }
        if mediaDiscarded == true { payload["mediaDiscarded"] = true }
        if let reason = captureFailure { payload["captureFailure"] = reason }
        if let failures = captureFailuresByCamera, !failures.isEmpty {
            payload["captureFailuresByCamera"] = failures
        }
        let manifest = mediaManifest
        if !manifest.isEmpty { payload["media"] = manifest }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

/// What ended an armed session without a clean disarm (BACKLOG 53). Rides
/// `Event.interruptionCause` as its raw value; `BootStamp.classify` tells the first two apart.
enum InterruptionCause: String, CaseIterable, Sendable {
    /// The device restarted while armed — a force-restart, a dead battery, an OS panic. The
    /// record appears at the next launch, which after a restart means after first unlock.
    case rebooted
    /// The app alone was ended while armed: force-quit, Voice Control "Close application",
    /// an OOM or app crash, or Guided Access ending with the app closed.
    case terminated
    /// An active session was sent to the background, where iOS stops the watch (32.R6).
    case backgrounded
    /// The app left the screen while armed under Guided Access (review 3, R3.3): the lock button is
    /// the usual way to background the app there, not the only one (a call or Siri, which SECURITY.md
    /// says can interrupt), so the record names the lock with that hedge (item 153's MAL-06). The raw value stays "locked" for
    /// the records already written. Whatever the tripwires could not see during it is compared
    /// against their baselines on resume where a tripwire has a state to compare (Power, Motion).
    case locked
    /// The countdown was sent to the background before the watch went live — a swipe-away
    /// during the grace seconds (item 74, line 6). Named for the countdown so the relaunch's
    /// "Arming did not complete" can stand down: one interruption, one record.
    case backgroundedDuringCountdown
}

enum DeviceInfo {
    /// Read once; avoids importing UIKit into the model layer everywhere. Written in the engine's
    /// init and at each arm, on the main actor, where every reader is (item 97: Swift 6 asks for
    /// the promise in words).
    nonisolated(unsafe) static var name: String = "Unknown Device"

    /// The hardware model identifier ("iPhone18,4") from the kernel — or, in the Simulator,
    /// from the environment the simulator sets. Empty when unavailable.
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = systemInfo.machine
        return withUnsafeBytes(of: machine) { raw in
            // Failable on purpose (lint's optional_data_string_conversion): a mangled
            // C-string degrades to "" → `marketingName` → plain "iPhone", never garbage.
            String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        }
    }

    /// Marketing name for a model identifier — the device-label FALLBACK (owner's call,
    /// 2026-08-30): iOS reports a generic "iPhone" to apps, so an unlabeled device's mirrors
    /// were anonymous; the model name is clearer, and two same-model devices in one log is
    /// less confusing than two called "iPhone". Pure (unit-tested). Unknown identifiers pass
    /// through unchanged — "iPhone20,1" is honest where a guessed name would be wrong — and
    /// an empty identifier falls back to plain "iPhone". The table is generated from the
    /// SDK's own device-type registry (`xcrun simctl list devicetypes`), not memory; extend
    /// it per new hardware generation, with every identifier a model answers to (Xcode lists a
    /// second one for some, such as the 18 Pro Max's iPhone19,7). `Item82FoldableTests` reads that
    /// registry and fails, naming each one, when an iPhone in it is missing here (item 82: the
    /// iPhone Duo was).
    static func marketingName(forIdentifier id: String) -> String {
        guard !id.isEmpty else { return "iPhone" }
        return modelNames[id] ?? id
    }

    private static let modelNames: [String: String] = [
        "iPhone11,2": "iPhone XS",        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",    "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini",   "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",    "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro",    "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",   "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14",        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",    "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",    "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",    "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro",    "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",        "iPhone18,4": "iPhone Air",
        "iPhone18,5": "iPhone 17e",
        "iPhone19,2": "iPhone 18 Pro",    "iPhone19,3": "iPhone 18 Pro Max",
        "iPhone19,4": "iPhone Duo",       "iPhone19,7": "iPhone 18 Pro Max"
    ]
}
