//
//  Item148DecoderFuzzTests.swift
//  MalinoisTests
//
//  BACKLOG 148's process point 2, item 145 step 11 (the owner's "do the fuzzing", 2026-10-21). Seeded fuzz tests of the
//  decoders that read what this run of the app did not just write: the journal's lines
//  (`EventStore.journaledEvents(in:)`), iCloud's evidence and status records (`CloudExfiltrator.event(from:)` and
//  `stateEvent(from:)`, with their bounds and allow-lists), and the stored lockout value
//  (`KeychainService.lockoutRemaining(stored:uptime:wallNow:)` and `lockoutValueIsWellFormed`). Each test has a fixed
//  seed, so its inputs are the same on every run: a failure names the seed and the input's number. Every input must end
//  without a trap and in the documented outcome: the line dropped, the record dropped, the value bounded or
//  allow-listed. Test-only: it records today's behaviour, including item 144's F5 (an unreadable journal line that is
//  not the last is dropped like a torn last line, and the lines after it are kept), without changing it.
//

import XCTest
import CloudKit
@testable import Malinois

/// SplitMix64: a small fixed generator, so a seed gives the same inputs on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The first few failures of a fuzz run, each with its seed and input number, so a bad input is reported a few times
/// rather than thousands.
private struct Findings {
    let seed: UInt64
    private(set) var messages: [String] = []
    private(set) var count = 0

    mutating func check(_ holds: Bool, _ input: Int, _ what: @autoclosure () -> String) {
        guard !holds else { return }
        count += 1
        if messages.count < 5 { messages.append("seed \(String(seed, radix: 16)), input \(input): \(what())") }
    }

    func report(file: StaticString = #filePath, line: UInt = #line) {
        for message in messages { XCTFail(message, file: file, line: line) }
        if count > messages.count { XCTFail("and \(count - messages.count) more", file: file, line: line) }
    }
}

@MainActor
final class Item148DecoderFuzzTests: XCTestCase {

    // MARK: - The journal

    /// Journals of real lines, each with one damage: a torn last line, a flipped bit, a line of garbage in place of a
    /// line or between two, or one value replaced by a hostile one. Every line the damage did not touch is read back,
    /// in order; a torn last line never is.
    func testTheJournalKeepsEveryLineTheDamageDidNotTouch() throws {
        let seed: UInt64 = 0x4A0B_0001
        var rng = SeededGenerator(seed: seed)
        var findings = Findings(seed: seed)
        let pool = Self.samples(&rng)
        let lines = try pool.map { try XCTUnwrap(EventStore.journalLine(for: $0)) }
        for input in 0..<2_000 {
            let picked = Array(pool.indices.shuffled(using: &rng).prefix(Int.random(in: 1...pool.count, using: &rng)))
            var parts = picked.map { lines[$0] }
            let target = Int.random(in: 0..<parts.count, using: &rng)
            var touched: UUID?
            var torn: UUID?
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:   // the last append cut mid-write: at least its closing brace and newline gone
                let last = parts[parts.count - 1]
                parts[parts.count - 1] = last.prefix(Int.random(in: 1..<(last.count - 1), using: &rng))
                torn = pool[picked[picked.count - 1]].id
            case 1:   // one bit flipped inside a line's JSON (never its newline, which would join two lines)
                var line = parts[target]
                let at = line.startIndex + Int.random(in: 0..<(line.count - 1), using: &rng)
                line[at] ^= UInt8(1) << UInt8.random(in: 0...7, using: &rng)
                parts[target] = line
                touched = pool[picked[target]].id
            case 2:   // a line replaced by garbage
                parts[target] = Self.garbage(&rng) + Data([0x0A])
                touched = pool[picked[target]].id
            case 3:   // a garbage line between two others (or first, or last)
                parts.insert(Self.garbage(&rng) + Data([0x0A]), at: Int.random(in: 0...parts.count, using: &rng))
            default:  // one value replaced by one this build cannot hold
                parts[target] = Self.hostileValue(in: parts[target], &rng)
                touched = pool[picked[target]].id
            }
            let read = EventStore.journaledEvents(in: parts.reduce(Data(), +))
            let ids = read.map(\.id)
            let kept = picked.map { pool[$0].id }.filter { $0 != touched && $0 != torn }
            findings.check(Self.isSubsequence(kept, of: ids), input, "a line the damage did not touch was lost")
            if let torn { findings.check(!ids.contains(torn), input, "a torn last line was read") }
            findings.check(read.count <= parts.count, input, "more events than lines")
            for event in read { Self.touchEveryDisplayProperty(event) }
        }
        findings.report()
    }

    /// Random bytes, newlines among them: no trap, never more events than lines, and whatever decodes renders.
    func testTheJournalReadsRandomBytesWithoutATrap() {
        let seed: UInt64 = 0x4A0B_0002
        var rng = SeededGenerator(seed: seed)
        var findings = Findings(seed: seed)
        for input in 0..<1_000 {
            let bytes = (0..<Int.random(in: 0...600, using: &rng)).map { _ -> UInt8 in
                Int.random(in: 0..<12, using: &rng) == 0 ? 0x0A : UInt8.random(in: 0...255, using: &rng)
            }
            let data = Data(bytes)
            let read = EventStore.journaledEvents(in: data)
            findings.check(read.count <= data.split(separator: 0x0A).count, input, "more events than lines")
            for event in read { Self.touchEveryDisplayProperty(event) }
        }
        findings.report()
    }

    /// Today's behaviour, stated once (item 144's F5): an unreadable line in the middle is dropped as silently as a torn
    /// last line, and every line after it is kept.
    func testAnUnreadableLineThatIsNotTheLastIsDroppedAndTheRestKept() throws {
        var rng = SeededGenerator(seed: 0x4A0B_0003)
        let pool = Self.samples(&rng)
        let first = try XCTUnwrap(EventStore.journalLine(for: pool[0]))
        let second = try XCTUnwrap(EventStore.journalLine(for: pool[1]))
        let third = try XCTUnwrap(EventStore.journalLine(for: pool[2]))
        let middle = first + Data("{\"id\":\"not a uuid\"".utf8) + Data([0x0A]) + second
        XCTAssertEqual(EventStore.journaledEvents(in: middle).map(\.id), [pool[0].id, pool[1].id])
        let tornLast = first + second + third.prefix(third.count / 2)
        XCTAssertEqual(EventStore.journaledEvents(in: tornLast).map(\.id), [pool[0].id, pool[1].id])
    }

    // MARK: - iCloud's records

    /// Evidence records with random fields of random types, in either namespace: decoded only with a real event id and
    /// start date, and then every value bounded or allow-listed as the decoder promises; nothing traps.
    func testCloudEvidenceRecordsAreBoundedOrDropped() {
        let seed: UInt64 = 0x4A0B_0004
        var rng = SeededGenerator(seed: seed)
        var findings = Findings(seed: seed)
        let reasons = Set(CaptureFailureReason.allCases.map(\.rawValue))
        let causes = Set(InterruptionCause.allCases.map(\.rawValue))
        for input in 0..<2_000 {
            let record = CKRecord(recordType: CloudExfiltrator.metaRecordTypeV2)
            let id: CKRecordValue? = Int.random(in: 0..<10, using: &rng) < 6
                ? Self.seededUUID(&rng).uuidString as CKRecordValue : Self.randomCloudValue(&rng)
            let start: CKRecordValue? = Int.random(in: 0..<10, using: &rng) < 6
                ? Self.randomDate(&rng) as CKRecordValue : Self.randomCloudValue(&rng)
            Self.set(record, "eventID", id, &rng)
            Self.set(record, "startDate", start, &rng)
            Self.set(record, "endDate", Bool.random(using: &rng) ? Self.randomDate(&rng) as CKRecordValue
                                                                   : Self.randomCloudValue(&rng), &rng)
            Self.set(record, "triggeredSensors", Bool.random(using: &rng) ? Self.sensorList(&rng) as CKRecordValue
                                                                          : Self.randomCloudValue(&rng), &rng)
            Self.set(record, "deviceName", Self.deviceNameValue(&rng), &rng)
            Self.set(record, "revision", Bool.random(using: &rng) ? Self.extremeInt(&rng) as CKRecordValue
                                                                  : Self.randomCloudValue(&rng), &rng)
            Self.set(record, "ownerAttributed", Self.randomCloudValue(&rng), &rng)
            Self.set(record, "metadataJSON", Self.metadataJSON(&rng) as CKRecordValue, &rng)

            let decoded = CloudExfiltrator.event(from: record)
            let identified = (id as? String).flatMap(UUID.init(uuidString:)) != nil && start is Date
            findings.check((decoded != nil) == identified, input, "decoded \(decoded != nil), identified \(identified)")
            guard let event = decoded else { continue }
            findings.check(event.startDate <= Date().addingTimeInterval(86_400), input, "start not clamped")
            findings.check(event.endDate >= event.startDate && event.endDate <= event.startDate.addingTimeInterval(86_400),
                           input, "end outside (start, start + 1 day]")
            findings.check(event.cloudRevision.map { (1...CloudExfiltrator.maxCloudRevision).contains($0) } ?? true,
                           input, "revision \(String(describing: event.cloudRevision)) out of bounds")
            findings.check(event.sustainedCount.map { (1...CloudExfiltrator.maxCloudSustainedCount).contains($0) } ?? true,
                           input, "sustained count out of bounds")
            findings.check(event.wrongPINCount.map { (1...CloudExfiltrator.maxCloudWrongPINCount).contains($0) } ?? true,
                           input, "wrong-PIN count out of bounds")
            for duration in [event.primaryDuration, event.secondaryDuration].compactMap({ $0 }) {
                findings.check(duration.isFinite && duration >= 0 && duration <= 86_400, input, "duration \(duration)")
            }
            for camera in [event.primaryCamera, event.secondaryCamera].compactMap({ $0 }) {
                findings.check(camera == "front" || camera == "rear", input, "camera \(camera)")
            }
            findings.check(event.cloudMediaManifest.map { !$0.isEmpty && Set($0).isSubset(of: CloudExfiltrator.allowedMediaTokens) } ?? true,
                           input, "manifest not allow-listed")
            findings.check(event.cloudMediaManifest.map { Set($0).count == $0.count } ?? true,
                           input, "manifest names one camera twice (1.8.2's step 32)")
            findings.check(Set(event.triggeredSensors).count == event.triggeredSensors.count,
                           input, "a tripwire listed twice (1.8.2's step 32)")
            findings.check(event.thermalState.map { ["nominal", "fair", "serious", "critical"].contains($0) } ?? true,
                           input, "thermal state not allow-listed")
            findings.check(event.interruptionCause.map { causes.contains($0) } ?? true, input, "cause not allow-listed")
            findings.check(event.captureFailure.map { reasons.contains($0) } ?? true, input, "failure not allow-listed")
            findings.check(event.captureFailuresByCamera.map { failures in
                failures.allSatisfy { ["front", "rear"].contains($0.key) && reasons.contains($0.value) }
            } ?? true, input, "failures by camera not allow-listed")
            let device = event.sourceDevice ?? ""
            findings.check(!device.isEmpty && device.count <= 64 && device.utf8.count <= CloudExfiltrator.maxDeviceNameBytes,
                           input, "device name \(device.count) characters, \(device.utf8.count) bytes")
            findings.check(event.cloudSyncState == .synced && event.mediaFilename == nil, input, "a mirror that claims a file")
            Self.touchEveryDisplayProperty(event)
        }
        findings.report()
    }

    /// Status records with random kinds and fields: every kind this build writes is admitted with a real id and date,
    /// and every kind admitted has words in the log, never "Signal loss" or the unrecognised-entry line; nothing traps.
    func testCloudStatusRecordsAreAdmittedOnlyWithWords() {
        let seed: UInt64 = 0x4A0B_0005
        var rng = SeededGenerator(seed: seed)
        var findings = Findings(seed: seed)
        let written = ["armed", "disarmed", "gaLifted", "cameraError", "armingCancelled", "armingInterrupted",
                       "thermalSerious", "thermalCritical", "soundUnavailable", "soundRestored", "unsyncedRemoved",
                       Event.backupOffKind, Event.backupOnKind, "motionStalled", "reinstalled",
                       "pinChanged", "guidedAccessEnded",   // item 153's MAL-03 and MAL-05
                       "reArmSkipped", "settingsReset",   // item 153's MAL-10; codex-10 on 1.8.2
                       Event.sirenElsewhereKind(device: "Owner's AirPods Pro"), Event.sirenElsewhereKind(device: "")]   // step 26
            + Event.protectionChangeKinds.sorted()
        // Numbers padded with zeros or signed with a plus read as the same number: dropped (1.8.2's step 32).
        let padded = ["clockChanged.060", "clockChanged.+60", "clockChanged.-060", "resumed.0252", "resumed.+252",
                      "clockChanged." + String(repeating: "0", count: 300) + "60", "settingSet.gracePeriod.015"]
        let junk = ["", "armed ", "ARMED", "Armed", "clockChanged.", "clockChanged.abc", "clockChanged.0",
                    "clockChanged.\(Int.min)", "clockChanged.\(Int.max)", "clockChanged.3153600001",
                    "settingOff.", "settingOff.unknown", "settingOn.touch", "someFutureKind", "signalLoss",
                    "sirenElsewhere. Car", "sirenElsewhere.Car ", "sirenElsewhere.Car\u{0}",   // 1.8.2's step 26
                    "sirenElsewhere." + String(repeating: "a", count: 41)] + padded
        let longest = (written + [Event.clockChangeKind(seconds: -100 * 365 * 86_400),
                                  Event.resumedKind(seconds: 100 * 365 * 86_400),
                                  Event.sirenElsewhereKind(device: String(repeating: "\u{1F600}", count: 40))])
            .map(\.utf8.count).max() ?? 0
        for input in 0..<2_000 {
            let kind: String
            var mustAdmit = false
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: kind = written.randomElement(using: &rng)!; mustAdmit = true
            case 1:
                let magnitude = Int.random(in: 1...(100 * 365 * 86_400), using: &rng)
                kind = Event.clockChangeKind(seconds: Bool.random(using: &rng) ? magnitude : -magnitude); mustAdmit = true
            case 2: kind = junk.randomElement(using: &rng)!
            default: kind = Self.randomString(&rng)
            }
            let record = CKRecord(recordType: CloudExfiltrator.stateRecordTypeV2)
            let identified = Int.random(in: 0..<10, using: &rng) < 8
            if identified {
                Self.set(record, "eventID", Self.seededUUID(&rng).uuidString as CKRecordValue, &rng)
                Self.set(record, "startDate", Self.randomDate(&rng) as CKRecordValue, &rng)
            } else {
                Self.set(record, "eventID", Self.randomString(&rng) as CKRecordValue, &rng)
                Self.set(record, "startDate", Self.randomCloudValue(&rng), &rng)
            }
            Self.set(record, "kind", kind as CKRecordValue, &rng)
            Self.set(record, "deviceName", Self.deviceNameValue(&rng), &rng)
            let decoded = CloudExfiltrator.stateEvent(from: record)
            if identified && mustAdmit { findings.check(decoded != nil, input, "a kind this build writes was dropped: \(kind)") }
            if padded.contains(kind) { findings.check(decoded == nil, input, "a padded number admitted: \(kind.prefix(30))") }
            guard let event = decoded else { continue }
            findings.check(kind.utf8.count <= longest, input, "an admitted kind longer than any this build writes")
            findings.check(event.stateChange == kind && event.triggeredSensors.isEmpty, input, "the kind changed: \(kind)")
            findings.check(event.startDate <= Date().addingTimeInterval(86_400), input, "start not clamped")
            let words = event.sensorSummary
            findings.check(words != "Signal loss" && words != "Status entry this version of Malinois does not recognize",
                           input, "an admitted kind without words: \(kind)")
            let device = event.sourceDevice ?? ""
            findings.check(!device.isEmpty && device.count <= 64 && device.utf8.count <= CloudExfiltrator.maxDeviceNameBytes,
                           input, "device name \(device.count) characters, \(device.utf8.count) bytes")
            Self.touchEveryDisplayProperty(event)
        }
        findings.report()
    }

    // MARK: - The stored lockout value

    /// Damaged stored values (numbers of every size, "nan" and "inf", stray separators, garbage): the wait read from
    /// them is finite and between zero and the longest wait, and neither rule traps.
    func testStoredLockoutValuesStayBounded() {
        let seed: UInt64 = 0x4A0B_0006
        var rng = SeededGenerator(seed: seed)
        var findings = Findings(seed: seed)
        let tokens = ["nan", "NaN", "inf", "-inf", "infinity", "1e309", "-1e309", "-0", "0x1p3", " 5", "5 ", "", "abc",
                      "١٢", "1_000", "+7", "9223372036854775807", "-9223372036854775808", "1e-320", "."]
        let separators = ["|", "||", "|||", " | "]
        for input in 0..<5_000 {
            let parts = (0..<Int.random(in: 0...4, using: &rng)).map { _ -> String in
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: return tokens.randomElement(using: &rng)!
                case 1: return String(Double.random(in: -1e12...1e12, using: &rng))
                default: return String(Int.random(in: -10_000...10_000_000, using: &rng))
                }
            }
            var stored = ""
            for (index, part) in parts.enumerated() {
                if index > 0 { stored += separators.randomElement(using: &rng)! }
                stored += part
            }
            let uptime = Double.random(in: 0...10_000_000, using: &rng)
            let wallNow = Double.random(in: 1_500_000_000...2_100_000_000, using: &rng)
            _ = KeychainService.lockoutValueIsWellFormed(stored, wallNow: wallNow)
            let wait = KeychainService.lockoutRemaining(stored: stored, uptime: uptime, wallNow: wallNow)
            findings.check(wait.isFinite && wait >= 0 && wait <= KeychainService.maxLockoutDelay, input,
                           "\"\(stored)\" read as a wait of \(wait) s")
        }
        findings.report()
    }

    // MARK: - Inputs

    /// Eight real events of different shapes, with ids from the generator.
    private static func samples(_ rng: inout SeededGenerator) -> [Event] {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return [
            Event(id: seededUUID(&rng), startDate: at, endDate: at.addingTimeInterval(5), triggeredSensors: [.motion, .touch],
                  mediaFilename: "a.jpg", primaryCamera: "front", primaryDuration: 5, motionTrace: [0.1, 2.5], sustainedCount: 3),
            Event(id: seededUUID(&rng), startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .synced,
                  stateChange: "armed"),
            Event(id: seededUUID(&rng), startDate: at, endDate: at, triggeredSensors: [],
                  stateChange: Event.clockChangeKind(seconds: 8_040)),
            Event(id: seededUUID(&rng), startDate: at, endDate: at, triggeredSensors: [.touch], wrongPINCount: 2),
            Event(id: seededUUID(&rng), startDate: at, endDate: at.addingTimeInterval(1), triggeredSensors: [],
                  interrupted: true, interruptionCause: InterruptionCause.allCases.first?.rawValue),
            Event(id: seededUUID(&rng), startDate: at, endDate: at, triggeredSensors: [.audio], cloudSyncState: .synced,
                  sourceDevice: "iPhone Air", cloudRevision: 2, cloudMediaManifest: ["front"]),
            Event(id: seededUUID(&rng), startDate: at, endDate: at, triggeredSensors: [], stateChange: "reinstalled"),
            Event(id: seededUUID(&rng), startDate: at, endDate: at, triggeredSensors: [.vision],
                  captureFailure: CaptureFailureReason.allCases.first?.rawValue, thermalState: "serious"),
        ]
    }

    private static func seededUUID(_ rng: inout SeededGenerator) -> UUID {
        let high = rng.next(), low = rng.next()
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            b[i] = UInt8(truncatingIfNeeded: high >> (8 * i))
            b[8 + i] = UInt8(truncatingIfNeeded: low >> (8 * i))
        }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Bytes that hold no newline, so they stay one line.
    private static func garbage(_ rng: inout SeededGenerator) -> Data {
        Data((0..<Int.random(in: 0...200, using: &rng)).map { _ -> UInt8 in
            let byte = UInt8.random(in: 0...255, using: &rng)
            return byte == 0x0A ? 0x0B : byte
        })
    }

    private static let hostileJSONValues: [Any] = [
        Int.max, Int.min, -1, 0, 1, 1e300, -1e300, 0.5, "", "x", String(repeating: "A", count: 2_000), "\u{1F415}\u{200D}\u{1F9BA}",
        [Any](), [String: Any](), NSNull(), true, false, [1, 2, 3], ["armed"], ["motion", "nonsense"],
    ]

    private static let hostileNumberTexts = ["NaN", "Infinity", "-Infinity", "1e999", "-1e999", "1e-999",
                                             "99999999999999999999999999", "-0", "\"text\"", "null", "[]", "{}", "true"]

    /// The line with one value replaced: a key's value swapped for a hostile JSON value, or a number's text for one
    /// that JSON cannot carry or this build cannot hold.
    private static func hostileValue(in line: Data, _ rng: inout SeededGenerator) -> Data {
        let json = line.dropLast()
        if Bool.random(using: &rng) {
            guard var object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                  let key = object.keys.sorted().randomElement(using: &rng) else { return line }
            object[key] = hostileJSONValues.randomElement(using: &rng)!
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return line }
            return data + Data([0x0A])
        }
        guard let text = String(data: json, encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: ":(-?[0-9][0-9.eE+-]*)") else { return line }
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.randomElement(using: &rng), let range = Range(match.range(at: 1), in: text) else {
            return line
        }
        var damaged = text
        damaged.replaceSubrange(range, with: hostileNumberTexts.randomElement(using: &rng)!)
        return Data(damaged.utf8) + Data([0x0A])
    }

    /// Strings from every corner: empty, long, emoji, combining marks, right-to-left, zero-width, control characters.
    private static func randomString(_ rng: inout SeededGenerator) -> String {
        let pieces = ["a", "Z", "0", "9", ",", "|", ".", "-", " ", "\u{0}", "\u{7}", "\n", "é", "e\u{301}", "\u{202E}",
                      "\u{200B}", "\u{1F415}", "ש", "日", "armed", "motion", "front", "rear", "iPhone"]
        var text = ""
        for _ in 0..<Int.random(in: 0...(Int.random(in: 0..<10, using: &rng) == 0 ? 300 : 12), using: &rng) {
            text += pieces.randomElement(using: &rng)!
        }
        return text
    }

    private static func randomDate(_ rng: inout SeededGenerator) -> Date {
        switch Int.random(in: 0..<5, using: &rng) {
        case 0: return Date().addingTimeInterval(Double.random(in: -3e8...3e8, using: &rng))
        case 1: return Date().addingTimeInterval(Double.random(in: 1e6...1e10, using: &rng))
        case 2: return Date(timeIntervalSinceReferenceDate: Double.random(in: -1e10...1e10, using: &rng))
        case 3: return Bool.random(using: &rng) ? .distantFuture : .distantPast
        default: return Date()
        }
    }

    private static func extremeInt(_ rng: inout SeededGenerator) -> Int {
        [Int.min, -1, 0, 1, 2, 3, 999, 1_000, 1_001, 100_000, 100_001, Int.max,
         Int.random(in: Int.min...Int.max, using: &rng)].randomElement(using: &rng)!
    }

    private static func sensorList(_ rng: inout SeededGenerator) -> String {
        let tokens = SensorType.allCases.map(\.rawValue) + ["", "nonsense", "MOTION", " motion", "camera,"]
        let length = Int.random(in: 0...(Int.random(in: 0..<10, using: &rng) == 0 ? 60 : 6), using: &rng)
        return (0..<length).map { _ in tokens.randomElement(using: &rng)! }.joined(separator: ",")
    }

    /// A device name: any cloud value, or now and then a heavy one, each character a letter with many accent marks
    /// (1.8.2's step 32: 64 characters can be any number of bytes).
    private static func deviceNameValue(_ rng: inout SeededGenerator) -> CKRecordValue? {
        guard Int.random(in: 0..<10, using: &rng) == 0 else { return randomCloudValue(&rng) }
        let character = "e" + String(repeating: "\u{301}", count: Int.random(in: 1...1_000, using: &rng))
        return String(repeating: character, count: Int.random(in: 1...70, using: &rng)) as CKRecordValue
    }

    /// A value of a random type CloudKit accepts in either namespace, or none.
    private static func randomCloudValue(_ rng: inout SeededGenerator) -> CKRecordValue? {
        switch Int.random(in: 0..<8, using: &rng) {
        case 0: return nil
        case 1: return randomString(&rng) as CKRecordValue
        case 2: return extremeInt(&rng) as CKRecordValue
        case 3: return Double.random(in: -1e12...1e12, using: &rng) as CKRecordValue
        case 4: return randomDate(&rng) as CKRecordValue
        case 5: return Data((0..<Int.random(in: 0...32, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }) as CKRecordValue
        case 6: return [randomString(&rng), randomString(&rng)] as CKRecordValue
        default: return [Int.random(in: -5...5, using: &rng)] as CKRecordValue
        }
    }

    /// A field in one namespace, chosen at random: the decoder reads the encrypted one first, then the plain one, and a
    /// real record holds each field in only one.
    private static func set(_ record: CKRecord, _ key: String, _ value: CKRecordValue?, _ rng: inout SeededGenerator) {
        guard let value else { return }
        if Bool.random(using: &rng) { record.encryptedValues[key] = value } else { record[key] = value }
    }

    /// The JSON blob's known keys with valid and hostile values, or text that is not JSON at all.
    private static func metadataJSON(_ rng: inout SeededGenerator) -> String {
        if Int.random(in: 0..<4, using: &rng) == 0 { return randomString(&rng) }
        let keys = ["interrupted", "interruptionCause", "capturedOffline", "sustainedCount", "primaryCamera",
                    "secondaryCamera", "primaryDuration", "secondaryDuration", "mediaDiscarded", "captureFailure",
                    "captureFailuresByCamera", "wrongPINCount", "thermalState", "media"]
        let valid: [Any] = ["front", "rear", "primary", "serious", 2, 5.0, true, ["front", "rear"],
                            ["front", "front", "rear", "front"],   // 1.8.2's step 32: each name kept once
                            ["front": CaptureFailureReason.allCases.first?.rawValue ?? "", "side": "x"],
                            InterruptionCause.allCases.first?.rawValue ?? ""]
        var object: [String: Any] = [:]
        for key in keys where Bool.random(using: &rng) {
            object[key] = Bool.random(using: &rng) ? valid.randomElement(using: &rng)! : hostileJSONValues.randomElement(using: &rng)!
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{" }
        return Bool.random(using: &rng) ? text : String(text.prefix(Int.random(in: 0...text.count, using: &rng)))
    }

    /// Reads every value the log shows for an event: a trap in one fails the run.
    private static func touchEveryDisplayProperty(_ event: Event) {
        _ = event.sensorSummary
        _ = event.durationSummary
        _ = event.shareClause
        _ = event.thermalStateSummary
        _ = event.isSignalLoss
        _ = event.duration
    }

    private static func isSubsequence(_ needles: [UUID], of haystack: [UUID]) -> Bool {
        var rest = haystack[...]
        for needle in needles {
            guard let at = rest.firstIndex(of: needle) else { return false }
            rest = rest[rest.index(after: at)...]
        }
        return true
    }
}
