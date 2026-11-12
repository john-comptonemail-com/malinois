//
//  SetAsideLog.swift
//  Malinois
//
//  An event log Malinois set aside because it could not be read as a whole (BACKLOG item 122; the owner, 2026-11-07: "as
//  you recommend, wording approved"; the design in docs/design/set-aside-log.md). Read record by record, so a record a
//  build cannot read, or damaged bytes, cost only what they touch; listed at the top of the Event Log, with a screen of its
//  own that shows what could be read, read only; shared as the file as kept, with the photos and clips it names and a
//  README. Nothing read from one goes back into the log: the signer has named its signed records gone, and that stays true.
//

import Foundation

/// A set-aside event log: the file `EventStore.setAside` kept, `events.corrupt-<seconds>.json` in the store's folder. The
/// app never writes it after setting it aside.
struct SetAsideLog: Identifiable, Equatable, Sendable {
    let url: URL
    var id: String { url.lastPathComponent }
    /// When it was set aside, from the seconds in its name; nil for a name without them.
    var setAsideAt: Date? { EventStore.corruptArtifactDate(url.lastPathComponent) }

    /// The name every set-aside event log starts with, as the media sweep's hold reads it.
    static let namePrefix = "events.corrupt-"

    /// The set-aside event logs in `root`, newest first: the plain files named `events.corrupt-…`, never the other files
    /// the app keeps apart (the limit's removals, the reports owed), and never a folder or a link under such a name, which
    /// only an edited backup restored to the phone can put there (item 218's Codex-1): the app sets aside files, and
    /// reads, shares and deletes nothing through a link or a folder. None when the folder cannot be listed. Those of
    /// one second are newest first too, by the number after the seconds in their names (`EventStore.setAsideURL`).
    static func all(in root: URL) -> [SetAsideLog] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasPrefix(namePrefix) && EventStore.isPlainFile(root.appendingPathComponent($0)) }
            .map { SetAsideLog(url: root.appendingPathComponent($0)) }
            .sorted { ($0.setAsideAt ?? .distantPast, $0.order, $0.id) > ($1.setAsideAt ?? .distantPast, $1.order, $1.id) }
    }

    /// This log's place among those set aside in its second: 1 for the first, by its name.
    var order: Int { EventStore.corruptArtifactOrder(url.lastPathComponent) }

    /// The forms in which a set-aside log's bytes are searched for a photo's or clip's name: as written, and, where they
    /// have a JSON `\u` escape, with each such escape of a plain character read as that character (item 230). A
    /// set-aside log does not decode as a whole, so it is searched and not decoded; its screen decodes the records that
    /// do decode. A name written with an escape for one of its letters, as only an edited backup writes it, was on the
    /// screen and not in the search: Delete of another set-aside log, and the limits' removals, took its photo.
    ///
    /// The search finds every spelling of a name the store gives, and of no wider name (item 231's Codex-10). Such a
    /// name is plain digits, capital letters, hyphens, a dot and "jpg" or "mov" (`EventStore.isStoredMediaName`): JSON
    /// writes each as itself or as its `\u` escape, and nothing else is the same name to the decoder or to a
    /// phone's file system. A quote, a tab or a backslash
    /// also has a short escape, a letter with an accent has two forms, and neither is read here; that is why a
    /// set-aside log names a file by the store's kind of name only, in its screen, its Share and its Delete. A file
    /// with no `\u`, as the app writes it, is searched as written, once (it is scanned once more, for `\u`).
    nonisolated static func searchForms(of bytes: Data) -> [Data] {
        guard bytes.range(of: Data([0x5C, 0x75])) != nil else { return [bytes] }
        let written = [UInt8](bytes)
        var read: [UInt8] = []
        read.reserveCapacity(written.count)
        var index = 0
        while index < written.count {
            guard written[index] == 0x5C, index + 1 < written.count else {
                read.append(written[index])
                index += 1
                continue
            }
            if written[index + 1] == 0x75, index + 5 < written.count,
               let character = plainCharacter(written[(index + 2)...(index + 5)]) {
                read.append(character)
                index += 6
            } else {
                // A backslash goes with what it escapes, so that an escaped backslash before a "u" is not read as the
                // start of an escape.
                read.append(written[index])
                read.append(written[index + 1])
                index += 2
            }
        }
        return [bytes, Data(read)]
    }

    /// The plain (ASCII) character the four hexadecimal digits of a JSON `\u` escape stand for; nil for any other
    /// character, whose escape is left as written.
    nonisolated private static func plainCharacter(_ digits: ArraySlice<UInt8>) -> UInt8? {
        var value: UInt32 = 0
        for digit in digits {
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = value * 16 + UInt32(digit - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value = value * 16 + UInt32(digit - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): value = value * 16 + UInt32(digit - UInt8(ascii: "A")) + 10
            default: return nil
            }
        }
        return value < 0x80 ? UInt8(value) : nil
    }

    /// Whether one of a set-aside log's search forms has `name`.
    nonisolated static func names(_ name: String, in forms: [Data]) -> Bool {
        forms.contains { $0.range(of: Data(name.utf8)) != nil }
    }

    /// What could be read of a set-aside log.
    struct Reading: Equatable, Sendable {
        /// The records it could read, in the file's order (newest first, as the log keeps them), each held to the limits a
        /// copy from iCloud is read under, as the log's own load does.
        var records: [Event]
        /// The parts it could not read: each record that did not decode, what follows where the list breaks off, and
        /// whatever but white space follows the list's end.
        var unreadable: Int
    }

    /// Pure (unit-tested): what `data` has, read record by record. A log is a JSON list of records, and each is read on its
    /// own, so a record this build cannot read (one with a value an older or newer build wrote) or damaged bytes inside one
    /// cost that record only. Where the list breaks off, or its bytes stop making a list, what follows counts as one
    /// unreadable part, and so does anything but white space after the list's end (item 218's Codex-3). A file that is
    /// not a list reads nothing, as one unreadable part; an empty file has nothing.
    static func reading(_ data: Data) -> Reading {
        let bytes = [UInt8](data)
        var index = 0
        func skipSpace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D {
                index += 1
            }
        }
        skipSpace()
        guard index < bytes.count else { return Reading(records: [], unreadable: 0) }
        guard bytes[index] == UInt8(ascii: "[") else { return Reading(records: [], unreadable: 1) }
        index += 1
        var records: [Event] = []
        var unreadable = 0
        while true {
            skipSpace()
            guard index < bytes.count else {   // cut off before the list's end
                unreadable += 1
                break
            }
            if bytes[index] == UInt8(ascii: "]") {
                // The list's end. Anything after it but white space is damage, and counts as one part (item 218's
                // Codex-3): the log's own decoder refuses it, which is how such a log came to be set aside.
                index += 1
                skipSpace()
                if index < bytes.count { unreadable += 1 }
                break
            }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            guard bytes[index] == UInt8(ascii: "{"), let end = objectEnd(in: bytes, from: index) else {
                unreadable += 1   // the list breaks off here: what follows is one part
                break
            }
            if let record = try? StoredJSON.decode(Event.self, from: Data(bytes[index...end])) {
                records.append(CloudExfiltrator.boundedCopy(record))
            } else {
                unreadable += 1
            }
            index = end + 1
        }
        return Reading(records: records, unreadable: unreadable)
    }

    /// The index of the `}` that closes the object opening at `start`, across nested objects and lists and skipping what is
    /// inside strings; nil when the bytes end first, or a list closes where the object should.
    private static func objectEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return byte == UInt8(ascii: "}") ? index : nil }
            }
            index += 1
        }
        return nil
    }

    /// What `log` has, read from its file: one unreadable part when the file itself cannot be read, or is not a plain
    /// file (a link is never read for the file it points to: item 218's Codex-1).
    static func read(_ log: SetAsideLog) -> Reading {
        guard EventStore.isPlainFile(log.url), let data = try? Data(contentsOf: log.url) else {
            return Reading(records: [], unreadable: 1)
        }
        return reading(data)
    }
}

/// What a set-aside log's Delete did (item 227's DS-5): the Event Log says so unless the log went with the photos and
/// clips only it names, as its confirmation says.
enum SetAsideLogDeletion: Equatable, Sendable {
    /// The log was not deleted, and nothing else was.
    case notDeleted
    /// The log is gone, and with it each photo and clip only it names: none, when it names none or others name them all.
    /// Also the answer when the log was gone already.
    case deleted
    /// The log is gone, and the photos and clips it names may still be on the phone: Malinois could not tell which are
    /// only its own (its bytes, the media folder, the event log on disk, a capture's record or another set-aside log
    /// could not be read, what is under a photo's name could not be looked at, or a link is where the event log or the
    /// captures still being saved are kept), or could not remove one.
    case deletedMediaLeft
}

/// What a set-aside log's Delete did, for the status entry that says so (item 234's A1).
struct SetAsideLogDeletionReport: Equatable, Sendable {
    let outcome: SetAsideLogDeletion
    /// Whether this Delete removed the log's file: not when nothing was deleted, nor when the log was gone already.
    let removedLog: Bool
    /// The records the log's bytes had, as its screen reads them; nil when the bytes could not be read.
    let records: Int?
    /// The photos and clips removed with it.
    let mediaRemoved: Int
}

/// The steps of a set-aside log's Delete on its screen (item 232; the owner, 2026-11-11: "as you recommend, wording
/// approved"): the PIN pad first, every time, then the confirmation. The Event Log may have been opened by a face or
/// finger, which opens what is read and must not delete; a PIN entered to open it is not taken for this. Kept apart
/// from the screen, pure and unit-tested, so that its rules hold whatever iOS tells the screen and in whatever order:
/// no confirmation without the PIN entered on the pad that was asked for; one confirmation for each entry; and nothing
/// the PIN opened here outlives Malinois's time on screen.
struct SetAsideLogDeleteSteps: Equatable {
    /// The PIN pad is up.
    var askingPIN = false
    /// The confirmation is up. The dialog itself sets this false when one of its buttons is pressed.
    var confirming = false
    /// The PIN was entered on the pad, which is closing: the confirmation opens once that pad has gone.
    private(set) var pinEntered = false

    /// The row's Delete was pressed: the pad. An entry that no pad's closing took up was for an earlier press, and is
    /// dropped: were iOS ever not to say that a pad has gone, the entry on it opens nothing later.
    mutating func deletePressed() {
        pinEntered = false
        askingPIN = true
    }

    /// The right PIN was entered on the pad: the pad closes, and the confirmation waits until it has gone. An entry on
    /// a pad no longer asked for (cancelled, or closed with the app, and not yet off the screen) is not taken.
    mutating func pinWasEntered() {
        guard askingPIN else { return }
        pinEntered = true
        askingPIN = false
    }

    /// The pad's Cancel.
    mutating func padWasCancelled() {
        askingPIN = false
    }

    /// The pad has gone: the confirmation, only after the PIN was entered on it, and once for each entry, so that the
    /// next Delete asks for the PIN again.
    mutating func padHasGone() {
        guard pinEntered else { return }
        pinEntered = false
        confirming = true
    }

    /// Malinois went to the background. What the PIN opened here does not outlive Malinois's time on screen, as Home
    /// closes the Event Log itself: the pad and the confirmation close, and an entry not yet used is dropped.
    mutating func malinoisLeftTheScreen() {
        askingPIN = false
        pinEntered = false
        confirming = false
    }
}

/// The words of a set-aside log's screens, in the owner's approved words (2026-11-07; Home's notice 2026-11-09, item 216).
enum SetAsideLogWords {
    /// Home, while any set-aside log is kept: what happened, and where the log is, in the words of its row in the Event Log
    /// (item 216; the owner, 2026-11-09: "a, 1").
    static let home = "Malinois set aside an event log it couldn't read. It's at the top of the Event Log."
    /// Its screen's title, and the start of its row in the Event Log.
    static let title = "Set-aside log"
    /// Under its screen's title. Its third sentence leaves out the rows marked `alsoInLog` (item 213's fable-3; Claude's
    /// draft, approved by the owner on 2026-11-08). Its last says what a badge on this screen is (item 227's DS-2): what
    /// the file recorded, which nothing checks again. It said that the records backed up to iCloud "are still there",
    /// and the app's own iCloud retention removes old full photos and clips as a matter of course.
    static let explanation = "This log couldn't be read as a whole, so Malinois set it aside and started a new one. These are the "
        + "records it could read. Except any marked below, they are not in your event log. A badge shows whether a record was "
        + "backed up to iCloud when the log was set aside; Malinois doesn't check again."
    /// Under a record the event log also has: the journal brought it back at the launch that set the log aside, or a pull
    /// from iCloud did (this phone's own uploaded records come back as copies under its name, without their photos and
    /// clips; item 214's note). Such a record shows no iCloud badge on the set-aside screens (item 214's fable-4).
    static let alsoInLog = "Also in your event log"
    /// Its screen, when no record could be read.
    static let noneReadable = "No records could be read."
    /// Delete's confirmation, its title and its message, and its button (item 122's decision 3 (a); the owner, 2026-11-07:
    /// the photos and clips only it names go at once, `EventStore.deleteSetAsideLog`). Since item 227 the message also
    /// says that they go from this iPhone whatever iCloud has of them (DS-2), and that the launch's sweep takes what no
    /// record names once no set-aside log is kept (DS-1: ADR 0078's decision 3, which nothing told the owner).
    static let deleteTitle = "Delete this set-aside log?"
    static let deleteMessage = "The photos and clips only it names are deleted from this iPhone too, whether or not iCloud has full "
        + "copies of them. After the last set-aside log is deleted, Malinois also clears photos and clips that no record names. "
        + "This can't be undone."
    static let deleteButton = "Delete"
    /// The title of the PIN pad Delete opens first (item 232; the owner, 2026-11-11: "wording approved"): a face or
    /// finger may open the Event Log, and never deletes from it.
    static let deletePINTitle = "Enter PIN to delete this log"
    /// What the Event Log says after a Delete that did less than its confirmation said (item 227's DS-5).
    struct DeleteNotice: Equatable, Sendable {
        let title: String
        let message: String
    }
    /// The notice after a Delete that removed the log and may have left its photos and clips, the one after a Delete
    /// that deleted nothing, and the button that dismisses either.
    static let deletedMediaLeftTitle = "Set-aside log deleted"
    static let deletedMediaLeftMessage = "Its photos and clips may still be on this iPhone: Malinois couldn't tell which were only "
        + "this log's, or couldn't remove them. Any that no record names are cleared later, once no set-aside log is kept."
    static let notDeletedTitle = "The set-aside log couldn't be deleted"
    static let notDeletedMessage = "Nothing was deleted."
    static let deleteNoticeButton = "OK"
    /// Pure (unit-tested): the Event Log's notice after a Delete, or nil when the log went with the photos and clips only
    /// it names.
    static func deleteNotice(for outcome: SetAsideLogDeletion) -> DeleteNotice? {
        switch outcome {
        case .deleted: return nil
        case .deletedMediaLeft: return DeleteNotice(title: deletedMediaLeftTitle, message: deletedMediaLeftMessage)
        case .notDeleted: return DeleteNotice(title: notDeletedTitle, message: notDeletedMessage)
        }
    }
    /// The README in its ZIP. Since item 232 (DS-1 of the second full review; the owner, 2026-11-11: "wording
    /// approved") it says which photos and clips the ZIP has: those still on the iPhone, as `SetAsideLogShare.folder`
    /// takes them, where it said "the photos and clips it names".
    static let readme = "This ZIP contains an event log Malinois set aside because it couldn't be read, with the photos and clips "
        + "it names that were still on the iPhone when it was shared. It is not signed evidence: it is the file as the phone "
        + "kept it. Malinois's verifier does not check it."

    /// The Event Log's row: "Set-aside log, Nov 7, 1:25 PM: 37 records, 2 unreadable", the time as the event log's own lines
    /// give one; no count of unreadable parts when there are none, and no time for a name without one.
    static func row(setAsideAt: Date?, records: Int, unreadable: Int) -> String {
        let when = setAsideAt.map { ", \($0.formatted(.dateTime.month(.abbreviated).day())), \($0.formatted(date: .omitted, time: .shortened))" }
        let count = records == 1 ? "1 record" : "\(records) records"
        let lost = unreadable > 0 ? ", \(unreadable) unreadable" : ""
        return "\(title)\(when ?? ""): \(count)\(lost)"
    }
}

/// Share of a set-aside log (item 122's decision 2 (a)): one ZIP of the file as the phone kept it, the photos and clips it
/// names that are on the phone, and a README saying it is not signed evidence.
enum SetAsideLogShare {
    /// The ZIP's name: "Malinois set-aside log" and when it was set aside, in the evidence ZIP's form ("2026-11-07 1325").
    static func name(for log: SetAsideLog) -> String {
        guard let at = log.setAsideAt else { return "Malinois set-aside log" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Malinois set-aside log " + formatter.string(from: at)
    }

    /// Writes the folder Share zips into `directory`: README.txt, the file as the phone kept it, byte for byte, and in Media
    /// each photo and clip on the phone, under a name the store gives (`EventStore.isStoredMediaName`, item 231's
    /// Codex-10), whose name the file's bytes have, as written or with a JSON escape read (`SetAsideLog.searchForms`);
    /// nil when the file cannot be read or is not a plain file. A file under any other name is not the log's, and is
    /// not carried, as the log's screen does not show it. The photos and clips are taken as plain
    /// files from a real media folder only (item 218's Codex-1): nothing is read through a link, in the log's place, the
    /// media folder's or a photo's, and a folder under a photo's name is not copied.
    static func folder(of log: SetAsideLog, mediaDirectory: URL, in directory: URL) throws -> URL? {
        guard EventStore.isPlainFile(log.url), let bytes = try? Data(contentsOf: log.url) else { return nil }
        let manager = FileManager.default
        let folder = directory.appendingPathComponent(name(for: log), isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data((SetAsideLogWords.readme + "\n").utf8).write(to: folder.appendingPathComponent("README.txt"))
        try bytes.write(to: folder.appendingPathComponent(log.url.lastPathComponent))
        let onPhone = EventStore.realDirectory(mediaDirectory)
            ? ((try? manager.contentsOfDirectory(atPath: mediaDirectory.path)) ?? []) : []
        let forms = SetAsideLog.searchForms(of: bytes)
        let named = onPhone.filter { name in
            EventStore.isStoredMediaName(name) && SetAsideLog.names(name, in: forms)
                && EventStore.isPlainFile(mediaDirectory.appendingPathComponent(name))
        }
        guard !named.isEmpty else { return folder }
        let media = folder.appendingPathComponent("Media", isDirectory: true)
        try manager.createDirectory(at: media, withIntermediateDirectories: true)
        for name in named.sorted() {
            try manager.copyItem(at: mediaDirectory.appendingPathComponent(name), to: media.appendingPathComponent(name))
        }
        return folder
    }

    /// Share's ZIP of `log`, in a folder of its own under `temporaryDirectory`, named as the evidence ZIP's are so that a
    /// launch clears one a share left behind (`EvidenceExporter.removeLeftovers`); nil when the file cannot be read or is
    /// not a plain file.
    static func zip(of log: SetAsideLog, mediaDirectory: URL,
                    temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> URL? {
        let manager = FileManager.default
        let place = temporaryDirectory.appendingPathComponent(EvidenceExporter.folderPrefix + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: place, withIntermediateDirectories: true)
        do {
            guard let folder = try folder(of: log, mediaDirectory: mediaDirectory, in: place) else {
                try? manager.removeItem(at: place)
                return nil
            }
            let zip = place.appendingPathComponent(folder.lastPathComponent + ".zip")
            try EvidenceExporter.zip(folder, to: zip)
            try manager.removeItem(at: folder)
            return zip
        } catch {
            try? manager.removeItem(at: place)
            throw error
        }
    }

    /// Once the share is over: removes the ZIP's folder.
    static func remove(_ zip: URL) {
        try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
    }
}
