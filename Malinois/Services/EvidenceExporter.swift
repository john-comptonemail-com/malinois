//
//  EvidenceExporter.swift
//  Malinois
//
//  The export bundle of a signed record (BACKLOG item 90, phase 4; the owner's rulings of 2026-10-31; ADR 0067), built
//  when the owner shares it: the signer signs an export statement, then the bundle takes every signature in the file's
//  order, in full the record's revisions, the status records of its watch (from the arm before it to the disarm after
//  it, in the log's order), the retention, absence and unkept statements (item 188) and the export statement, every
//  other as its hash; the phone's notes; and the attachments the record's latest revision signed, from the files on the
//  phone. iOS zips the folder. A record with no signature of this phone's has no bundle and is shared as before, as is
//  one whose export statement no key can sign (item 187).
//

import Foundation

struct EvidenceExporter: Sendable {
    let signer: EvidenceSigner
    /// The folder of the log's photo and clip files.
    let mediaDirectory: URL
    /// Where bundles are built: the app's temporary folder.
    let temporaryDirectory: URL

    #if DEBUG
    /// Test-only: run between the check of the photo and clip files' bytes and their lookup for the bundle, where the
    /// store's storage cleanup can come (item 190's codex-4 on 29d6501).
    nonisolated(unsafe) static var afterTheBytesCheckForTesting: (@Sendable () -> Void)?
    #endif

    init(signer: EvidenceSigner, mediaDirectory: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.signer = signer
        self.mediaDirectory = mediaDirectory
        self.temporaryDirectory = temporaryDirectory
    }

    /// The bundle of `record`, zipped, in a folder of its own in the temporary folder, ready to share: `log` is the event
    /// log as the app holds it. nil when the record has no signature of this phone's, no key could sign its export
    /// statement (item 187, deepseek-1), the signature file cannot be read now, or the record's photos, clips and traces
    /// are not the bytes its latest revision signed, on the phone or as copied (item 190). The caller removes the ZIP's
    /// folder once the share is done.
    func bundle(of record: Event, log: [Event]) async throws -> URL? {
        let manager = FileManager.default
        let place = temporaryDirectory.appendingPathComponent(Self.folderPrefix + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: place, withIntermediateDirectories: true)
        do {
            guard let folder = try await folder(of: record, log: log, in: place) else {
                try? manager.removeItem(at: place)
                return nil
            }
            let zip = place.appendingPathComponent(folder.lastPathComponent + ".zip")
            try Self.zip(folder, to: zip)
            try manager.removeItem(at: folder)
            return zip
        } catch {
            try? manager.removeItem(at: place)
            throw error
        }
    }

    /// Signs the export statement and writes the bundle's folder into `directory`; nil as for `bundle(of:log:)`, a folder
    /// written whose copies are not the bytes signed left for the caller to remove.
    func folder(of record: Event, log: [Event], in directory: URL) async throws -> URL? {
        // What the bundle shows of the log, named in its export statement (item 182, the owner's "B").
        let showing = Self.watch(around: record, in: log).union([record.id])
        guard let snapshot = await signer.export(of: record.id, showing: showing),
              let made = Self.assembled(of: record, log: log, snapshot: snapshot, mediaDirectory: mediaDirectory) else {
            return nil
        }
        let folder = directory.appendingPathComponent(Self.bundleName(for: record), isDirectory: true)
        try EvidenceBundle.write(made.contents, to: folder)
        // The copies as written are the bytes the latest revision signed (item 190's codex-4 on 29d6501, the owner's "b"):
        // a photo or clip the store replaced after the check and before its copy makes no bundle.
        guard Self.holds(made.contents.attachments, in: folder, asSigned: made.signed) else { return nil }
        return folder
    }

    /// What the bundle of `record` holds, from the signature file's `snapshot` and the log; nil when the record has no
    /// signature in it.
    static func contents(of record: Event, log: [Event], snapshot: EvidenceExportSnapshot,
                         mediaDirectory: URL) -> EvidenceBundle.Contents? {
        assembled(of: record, log: log, snapshot: snapshot, mediaDirectory: mediaDirectory)?.contents
    }

    /// A bundle's contents, with the attachments the record's latest revision signed, which its copies must be.
    private struct Assembled {
        let contents: EvidenceBundle.Contents
        let signed: [EvidenceForm.Attachment]
    }

    /// `contents`, with the attachments the record's latest revision signed.
    private static func assembled(of record: Event, log: [Event], snapshot: EvidenceExportSnapshot,
                                  mediaDirectory: URL) -> Assembled? {
        let watch = watch(around: record, in: log)
        let lastSignature = snapshot.entries.lastIndex { $0.kind == .signature }
        // The keys the signer acts on, by the same rule (item 182, codex-1 on 68bd96b3).
        let keys = EvidenceSignatureFile.listedKeys(in: snapshot.entries).map {
            EvidenceBundle.Key(id: $0.key, statement: $0.statement, attestation: $0.attestation)
        }
        var signatures: [EvidenceBundle.Signature] = []
        var notes: [EvidenceBundle.Note] = []
        var latest: EvidenceForm.Record?
        for (index, entry) in snapshot.entries.enumerated() {
            switch entry.kind {
            case .keyLost:
                if let key = entry.key { notes.append(.keyLost(key: key, at: entry.at.flatMap(EvidenceForm.milliseconds(since1970:)))) }
            case .signature:
                guard let key = entry.key, let statement = entry.statement, let assertion = entry.assertion else { continue }
                var shown = false
                switch try? EvidenceForm.read(statement) {
                case .record(let revision)?:
                    shown = revision.id == record.id || watch.contains(revision.id)
                    if revision.id == record.id { latest = revision }
                case .retention?, .absence?, .unkept?:
                    // What the limit retired, what left the log otherwise (item 182), and the signatures made and not kept,
                    // which a verifier counts only when it reads them (item 188).
                    shown = true
                case .export?:
                    // This export's only: an earlier share's is shown as its hash, like any other record's.
                    shown = snapshot.signedExport && index == lastSignature
                case .key?, nil:
                    break
                }
                signatures.append(EvidenceBundle.Signature(key: key, assertion: assertion, statement: statement, shown: shown))
            case .keyPending, .keyCertified, .unsupported, .absenceLogged, .historyMissing:
                break
            }
        }
        guard let latest else { return nil }
        // Only the bytes the latest revision signed (item 190, deepseek-2): the record as the share holds it, its
        // attachments made as the signer makes them, must be what that revision signed. A change the signer has not
        // signed yet (a thumbnail replaced, a photo attached, a clip the limit removed) makes no bundle, which the
        // phone's own check would read as altered; the record waits for the signer's next pass.
        guard attachmentsAsSigned(of: record, mediaDirectory: mediaDirectory) == latest.attachments else { return nil }
        #if DEBUG
        afterTheBytesCheckForTesting?()
        #endif
        // Every attachment the latest revision signed, or no bundle (item 190's codex-4 on 29d6501, the owner's "b"): the
        // store's storage cleanup, on its own queue, can remove a file after the check above.
        var attachments: [EvidenceBundle.Attachment] = []
        for signed in latest.attachments {
            guard let found = attachment(named: signed.name, of: record, mediaDirectory: mediaDirectory) else { return nil }
            attachments.append(found)
        }
        let contents = EvidenceBundle.Contents(record: record.id, keys: keys, signatures: signatures, notes: notes,
                                               attachments: attachments)
        return Assembled(contents: contents, signed: latest.attachments)
    }

    /// Whether the attachment files written in `folder` are the bytes `signed` names: one for each, in the order
    /// `assembled` puts them (item 190's codex-4 on 29d6501).
    private static func holds(_ attachments: [EvidenceBundle.Attachment], in folder: URL,
                              asSigned signed: [EvidenceForm.Attachment]) -> Bool {
        Swift.zip(attachments, signed).allSatisfy { written, expected in
            let copy = folder.appendingPathComponent("\(EvidenceBundle.attachmentsFolder)/\(written.file)")
            return (try? EvidenceHash.digest(ofFileAt: copy)) == expected.digest
        }
    }

    /// The status records of the watch around `record` in `log`: this phone's own, from the arm before it (or the record
    /// itself, when no arm comes before) to the disarm after it (or the end of the log, or the next arm), the record left
    /// out. Status records are the state changes and the interruptions; other incidents are not among them. In the order
    /// things happened on this phone, the log's own (newest first, as the store keeps it; ADR 0069, section 6), never by
    /// the records' times, which the phone's clock sets (item 187, codex-2 on 09d997f).
    static func watch(around record: Event, in log: [Event]) -> Set<UUID> {
        // This phone's own records, oldest first: another device's arm or disarm is not this phone's watch.
        let ordered = Array(log.filter { !$0.isMirrored }.reversed())
        guard let index = ordered.firstIndex(where: { $0.id == record.id }) else { return [] }
        let start = ordered[...index].lastIndex { $0.stateChange == "armed" } ?? index
        var end = ordered.count - 1
        for later in index..<ordered.count {
            if ordered[later].stateChange == "disarmed" {
                end = later
                break
            }
            if later > index, ordered[later].stateChange == "armed" {
                end = later - 1
                break
            }
        }
        // The end is never before the record, so never before the start; were it, the window would be the record alone
        // rather than a stop of the app as the owner shares.
        let window = ordered[start...max(start, end)]
        return Set(window.filter { $0.id != record.id && ($0.isStateChange || $0.interrupted == true) }.map(\.id))
    }

    /// Removes the folders bundles were made in that a share left behind (the app ended with its sheet open): at launch,
    /// when no sheet is open.
    static func removeLeftovers(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: temporaryDirectory.path) else { return }
        for name in names where name.hasPrefix(folderPrefix) {
            // Only a folder named as a bundle's: the prefix, then a UUID as this code writes one.
            let identifier = String(name.dropFirst(folderPrefix.count))
            guard UUID(uuidString: identifier)?.uuidString == identifier else { continue }
            try? manager.removeItem(at: temporaryDirectory.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// The start of the name of the folder each bundle is made in.
    static let folderPrefix = "MalinoisExport-"

    /// The bundle's name: "Malinois evidence", then the record's date and time on the phone's clock.
    static func bundleName(for record: Event) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Malinois evidence \(formatter.string(from: record.startDate))"
    }

    // MARK: - Helpers

    /// An attachment the latest revision signed, from the record as the phone holds it now: a photo or clip from its file
    /// (while it is still a plain file in the media folder), the thumbnail, a trace's bytes.
    private static func attachment(named name: String, of record: Event, mediaDirectory: URL) -> EvidenceBundle.Attachment? {
        switch name {
        case "primary": return mediaFile(record.mediaFilename, as: name, in: mediaDirectory)
        case "secondary": return mediaFile(record.secondaryMediaFilename, as: name, in: mediaDirectory)
        case "thumbnail": return record.thumbnailData.map { EvidenceBundle.Attachment(name: name, file: "thumbnail.jpg", source: .bytes($0)) }
        case "motionTrace": return trace(record.motionTrace, as: name)
        case "audioTrace": return trace(record.audioTrace, as: name)
        case "visionTrace": return trace(record.visionTrace ?? [], as: name)
        default: return nil
        }
    }

    /// The record's attachments as the signer would sign them now (`Event.evidenceAttachments`): its photo and clip files'
    /// digests, read by the signer's rule, a plain file in the media folder or none; nil when one is there and is not a
    /// plain file, or cannot be read (item 190, deepseek-2).
    private static func attachmentsAsSigned(of record: Event, mediaDirectory: URL) -> [EvidenceForm.Attachment]? {
        var digests: [EvidenceForm.Digest?] = []
        for filename in [record.mediaFilename, record.secondaryMediaFilename] {
            guard let filename, let url = EvidenceSigner.mediaFile(named: filename, in: mediaDirectory),
                  let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else {
                digests.append(nil)
                continue
            }
            guard type == .typeRegular, let digest = try? EvidenceHash.digest(ofFileAt: url) else { return nil }
            digests.append(digest)
        }
        return record.evidenceAttachments(primary: digests[0], secondary: digests[1])
    }

    /// A photo or clip as the bundle holds it: named for its attachment, with its file's extension when that is a plain one.
    private static func mediaFile(_ filename: String?, as name: String, in directory: URL) -> EvidenceBundle.Attachment? {
        guard let filename, let url = EvidenceSigner.mediaFile(named: filename, in: directory),
              (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular else {
            return nil
        }
        let withExtension = "\(name).\((filename as NSString).pathExtension)"
        let file = EvidenceBundle.isPlainFileName(withExtension, of: name) ? withExtension : name
        return EvidenceBundle.Attachment(name: name, file: file, source: .file(url))
    }

    private static func trace(_ samples: [Double], as name: String) -> EvidenceBundle.Attachment {
        EvidenceBundle.Attachment(name: name, file: "\(name).bin", source: .bytes(EvidenceForm.traceBytes(samples)))
    }

    /// Zips `folder` into `destination` as iOS does for uploading: the folder itself, in a standard ZIP.
    private static func zip(_ folder: URL, to destination: URL) throws {
        var coordination: NSError?
        var copying: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
            // The ZIP iOS makes lasts only while this runs.
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copying = error
            }
        }
        if let coordination { throw coordination }
        if let copying { throw copying }
    }
}
