//
//  Event+Evidence.swift
//  Malinois
//
//  A record as evidence signing signs it (BACKLOG item 90, `EvidenceForm`'s record layout): its facts, in a fixed order,
//  and its attachments, each covered by its hash. Every stored field of `Event` is either a fact here or named in
//  `notEvidenceFields` with the reason, and a test holds the two lists to the type, so a new field cannot join the log
//  without someone deciding whether it is evidence.
//

import Foundation

extension Event {
    /// The stored fields that are not facts, each with the reason.
    static let notEvidenceFields: [String: String] = [
        "id": "the statement names the record by it",
        "mediaFilename": "a file name on this phone; the attachment covers the file itself",
        "secondaryMediaFilename": "a file name on this phone; the attachment covers the file itself",
        "thumbnailData": "covered by its attachment's hash",
        "motionTrace": "covered by its attachment's hash",
        "audioTrace": "covered by its attachment's hash",
        "visionTrace": "covered by its attachment's hash",
        "cloudSyncState": "upload bookkeeping, which changes as the upload goes",
        "sourceDevice": "marks another device's copy, which this phone does not sign",
        "cloudRevision": "upload bookkeeping: the generation of the record iCloud holds",
        "mediaDiscardUnchecked": "upload bookkeeping, kept on this phone only",
        "uploadedMedia": "upload bookkeeping, kept on this phone only",
        "receiptEpoch": "upload bookkeeping, kept on this phone only",
        "keptLocal": "whether the record may upload, not what it records",
        "cloudMediaManifest": "another device's list of its uploads, on its copies only",
    ]

    /// The record's facts, in their fixed order, every one always present (null when the record has no value). Times
    /// and lengths are whole milliseconds, null when none can hold them (a damaged log's); a flag the record leaves
    /// unset is false, as the app reads it.
    var evidenceFacts: [EvidenceJSON.Member] {
        func text(_ value: String?) -> EvidenceJSON { value.map(EvidenceJSON.string) ?? .null }
        func number(_ value: Int?) -> EvidenceJSON { value.map { EvidenceJSON.int(Int64($0)) } ?? .null }
        func time(_ date: Date) -> EvidenceJSON { EvidenceForm.milliseconds(since1970: date).map(EvidenceJSON.int) ?? .null }
        func length(_ seconds: Double?) -> EvidenceJSON {
            seconds.flatMap { EvidenceForm.milliseconds($0) }.map(EvidenceJSON.int) ?? .null
        }
        // Each camera once, in the order of their names' bytes, so the dictionary's own order never shows.
        let failures = (captureFailuresByCamera ?? [:])
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .map { EvidenceJSON.Member($0.key, .string($0.value)) }
        return [
            EvidenceJSON.Member("startDate", time(startDate)),
            EvidenceJSON.Member("endDate", time(endDate)),
            EvidenceJSON.Member("triggeredSensors", .array(triggeredSensors.map { EvidenceJSON.string($0.rawValue) })),
            EvidenceJSON.Member("stateChange", text(stateChange)),
            EvidenceJSON.Member("interrupted", .bool(interrupted == true)),
            EvidenceJSON.Member("interruptionCause", text(interruptionCause)),
            EvidenceJSON.Member("sustainedCount", number(sustainedCount)),
            EvidenceJSON.Member("wrongPINCount", number(wrongPINCount)),
            EvidenceJSON.Member("cancelCount", number(cancelCount)),
            EvidenceJSON.Member("ownerAttributed", .bool(ownerAttributed == true)),
            EvidenceJSON.Member("capturedOffline", .bool(capturedOffline == true)),
            EvidenceJSON.Member("thermalState", text(thermalState)),
            EvidenceJSON.Member("captureFailure", text(captureFailure)),
            EvidenceJSON.Member("captureFailuresByCamera", failures.isEmpty ? .null : .object(failures)),
            EvidenceJSON.Member("primaryCamera", text(primaryCamera)),
            EvidenceJSON.Member("primaryDuration", length(primaryDuration)),
            EvidenceJSON.Member("secondaryCamera", text(secondaryCamera)),
            EvidenceJSON.Member("secondaryDuration", length(secondaryDuration)),
            EvidenceJSON.Member("mediaDiscarded", .bool(mediaDiscarded == true)),
        ]
    }

    /// The record's attachments, in their fixed order: its photo or clip files (`primary`, `secondary`: their digests,
    /// which the caller reads, knowing where the files are), the thumbnail, and each sensor trace with samples.
    func evidenceAttachments(primary: EvidenceForm.Digest?, secondary: EvidenceForm.Digest?) -> [EvidenceForm.Attachment] {
        var attachments: [EvidenceForm.Attachment] = []
        if let primary { attachments.append(EvidenceForm.Attachment(name: "primary", digest: primary)) }
        if let secondary { attachments.append(EvidenceForm.Attachment(name: "secondary", digest: secondary)) }
        if let thumbnailData {
            attachments.append(EvidenceForm.Attachment(name: "thumbnail", digest: EvidenceHash.digest(of: thumbnailData)))
        }
        let traces = [("motionTrace", motionTrace), ("audioTrace", audioTrace), ("visionTrace", visionTrace ?? [])]
        for (name, samples) in traces where !samples.isEmpty {
            attachments.append(EvidenceForm.Attachment(name: name, digest: EvidenceHash.digest(of: EvidenceForm.traceBytes(samples))))
        }
        return attachments
    }

    /// One revision of the record, ready to sign: its `revision` number, the phone's clock at signing, and the app's
    /// version and build ("1.10 (81)").
    func evidenceRecord(revision: Int64, signedAt: Date, app: String,
                        primary: EvidenceForm.Digest?, secondary: EvidenceForm.Digest?) -> EvidenceForm.Record {
        // The phone's clock now is always a whole number of milliseconds since 1970 well inside the range.
        EvidenceForm.Record(id: id, revision: revision, signedAt: EvidenceForm.milliseconds(since1970: signedAt) ?? 0, app: app,
                            facts: evidenceFacts, attachments: evidenceAttachments(primary: primary, secondary: secondary))
    }
}

/// What a record of this phone's is, apart from its ID: its start, its kind (an incident, or which status entry) and
/// whether it is an interruption record, which the app never changes once it has made a record (item 182, codex-2 on
/// 21ea9a43 and codex-1 on c2202a26): a row under a signed record's ID with another is another record. The log's limit
/// chooses its pool by the last two (`EventStore.pruneToCountCap`).
struct RecordIdentity: Hashable, Codable, Sendable {
    /// When the record started, in milliseconds by the phone's clock, as its "startDate" fact holds it.
    let start: Int64?
    /// Its "stateChange" fact: nil for an incident.
    let kind: String?
    /// Its "interrupted" fact: a record of monitoring interrupted, which the log's limit counts with the status entries
    /// (codex-1 on c2202a26, the owner's "a").
    let interrupted: Bool

    init(start: Int64?, kind: String?, interrupted: Bool = false) {
        self.start = start
        self.kind = kind
        self.interrupted = interrupted
    }
}

extension Event {
    /// This record's identity (`RecordIdentity`).
    var evidenceIdentity: RecordIdentity {
        RecordIdentity(start: EvidenceForm.milliseconds(since1970: startDate), kind: stateChange, interrupted: interrupted == true)
    }
}
