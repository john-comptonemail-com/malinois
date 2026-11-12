//
//  MalinoisVerifier.swift
//  MalinoisVerifier
//
//  The Mac verifier of a Malinois evidence bundle (BACKLOG item 90, phase 5; ADR 0068). It checks the ZIP that Share
//  sent, or the folder it unzips to, with the evidence core the phone signs with (`MalinoisEvidence/`), against Apple's
//  App Attestation root, and reports what it checked: each key Apple certified, every signature in the phone's order,
//  each key's counters (those a key's own unkept statement names said to be made by App Attest and not kept by the
//  phone, as information: item 188), the export, the shared record's revisions and its attachments, and any other file,
//  in the bundle or beside its folder, which is a problem (item 187); then PASS, or the problems.
//  It knows a key is Malinois's by the SHA-256 of Malinois's App ID, as every Malinois attestation carries it, so the
//  team ID is never in this source; Apple's root is built in, and a reader may give a copy of their own (the owner's
//  rulings of 2026-10-31). A ZIP's listing is read before it is unpacked, and a link, a path outside it or more bytes
//  than a phone keeps of media is refused. What a bundle, a ZIP or a path says reaches the report only as text (`shown`,
//  `displayed`; item 197's codex-2). Needs macOS's trust service: run it as an ordinary program.
//

import Foundation
import Security

enum MalinoisVerifier {
    /// The SHA-256 of Malinois's App ID (its developer's team ID and its bundle ID), as Apple writes it into every
    /// Malinois attestation: a key certified for any other app is refused.
    static let appIDHash = EvidenceHash.bytes(hex: "d7c30790792071e204e7f0d71a674ff9268cffc327fc89a5a5a238329def69e7") ?? Data()

    /// Apple's App Attestation Root CA (valid to 2045-03-15), as Apple publishes it at
    /// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem (DER).
    static let appleRoot = der(pem: """
        -----BEGIN CERTIFICATE-----
        MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
        JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
        QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
        Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
        biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
        bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
        NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
        Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
        MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
        CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
        53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
        oyFraWVIyd/dganmrduC1bmTBGwD
        -----END CERTIFICATE-----
        """) ?? Data()

    /// The most a bundle's ZIP may unpack to: the phone keeps about 2 GB of media in all.
    static let largestUnpacked: Int64 = 4 << 30

    static let usage = """
        usage: malinois-verify BUNDLE [--root ROOT]
          BUNDLE  the ZIP that Malinois's Share sent, or the folder it unzips to
          --root  a copy of Apple's App Attestation Root CA (PEM or DER) to check against instead of the built-in one

        """

    /// What a run printed, and its exit status: 0 the bundle checks out, 1 the report names problems, 2 nothing was
    /// checked (the arguments, the root or the bundle could not be read).
    struct Outcome: Equatable, Sendable {
        let text: String
        let status: Int32
    }

    /// Checks the bundle the command line names (`arguments`, without the program's name) for the app whose App ID has
    /// the SHA-256 `appIDHash` (Malinois's; a test's own in the tests). The text it returns holds no control character but
    /// its own line breaks (`displayed`), and each value a sender supplies is `shown`, so no line in it is the sender's.
    /// `check` does the checking, which a test may stand in for.
    static func run(_ arguments: [String], appIDHash: Data = appIDHash,
                    check: ([String], Data) -> Outcome = checked) -> Outcome {
        let outcome = check(arguments, appIDHash)
        return Outcome(text: displayed(outcome.text), status: outcome.status)
    }

    static func checked(_ arguments: [String], appIDHash: Data) -> Outcome {
        guard let (path, rootPath) = parse(arguments) else { return Outcome(text: usage, status: 2) }
        var root = (der: appleRoot, name: "Apple's App Attestation Root CA, built in")
        if let rootPath {
            guard let der = rootCertificate(at: URL(fileURLWithPath: rootPath)) else {
                return Outcome(text: "No root certificate could be read from \(shown(rootPath)): nothing was checked.\n", status: 2)
            }
            root = (der, "the root certificate in \(shown(rootPath))")
        }
        let target = URL(fileURLWithPath: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder) else {
            return Outcome(text: "There is no file or folder at \(shown(path)): nothing was checked.\n", status: 2)
        }
        if isFolder.boolValue { return check(target, given: target, root: root, appIDHash: appIDHash) }
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("malinois-verify-\(UUID().uuidString)",
                                                                                     isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        if let reason = unpack(target, into: unpacked) {
            return Outcome(text: "\(shown(path)) was not unpacked: \(shown(reason)). Nothing was checked.\n", status: 2)
        }
        return check(unpacked, given: target, root: root, appIDHash: appIDHash)
    }

    /// Why a ZIP must not be unpacked, from its listing by `zipinfo -l`: an entry that is a link, that names a path from
    /// the root or outside the ZIP, more bytes than `largestUnpacked`, or a listing this cannot read; nil when it may be.
    static func refusal(ofListing listing: String) -> String? {
        guard let listed = entries(inListing: listing) else { return "its listing could not be read" }
        for (mode, name) in listed.entries {
            if mode.hasPrefix("l") { return "it contains a link (\(name))" }
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") { return "it names a path outside itself (\(name))" }
        }
        if listed.unpackedBytes > largestUnpacked {
            return "it would unpack to \(listed.unpackedBytes) bytes, more than a phone keeps of media"
        }
        return nil
    }

    /// Why a ZIP must not be read (item 187, codex-1 on 3096c70, and round E) unless it is laid out as one plain ZIP: one
    /// unbroken run of files from its first byte, each file's own header naming it as the index does (its position, name,
    /// flags, method, checksum and sizes, or zero sizes and a data descriptor that does), a stored file's two sizes the
    /// same, and after its data only when both are 0, a folder's entry holding nothing, each file's extra fields, in its
    /// header and in the index, of the kinds genuine ZIPs carry, the index right after the last file and the end record
    /// right after the index, nothing after that but a comment that holds no end record's signature; no ZIP64, split,
    /// encrypted or otherwise compressed file. Readers that go by the index and readers that read a ZIP front to back then
    /// take the same bytes for each file under the same name; in a ZIP that holds a second archive, or whose index or
    /// headers name a file otherwise, they do not. It interprets the headers only: whether a compressed file's stream
    /// fills the bytes it is given, `bsdtar` checks as it unpacks it (deepseek-2 on c68e3ec). Nil when the layout holds.
    static func refusal(ofLayout file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "it could not be read" }
        defer { try? handle.close() }
        do {
            try ZIPLayout(handle: handle).check()
            return nil
        } catch let problem as ZIPLayout.Problem {
            return problem.text == ZIPLayout.Problem.noEnd.text ? "it is not a ZIP that macOS can read"
                : "it is not laid out as one plain ZIP (\(problem.text))"
        } catch {
            return "it could not be read"
        }
    }

    /// Why a ZIP must not be unpacked when its readings disagree (item 187, codex-1 on fde1689): its listing by `zipinfo
    /// -l` (the ZIP's index), `bsdtar -tv` reading it as it unpacks it (`unpacking`), and `bsdtar -tv` reading it front
    /// to back from each entry's own header (`streaming`) must name the same entries, each of the same kind, in any
    /// order; nil when they do. A ZIP's index and an entry's header can name it differently, and macOS's unzip tool
    /// writes the header's name: an entry the index names as a folder would be unpacked as a file past the count, and an
    /// entry the index leaves out shows only to a reader that reads a ZIP front to back.
    static func refusal(ofListing listing: String, unpacking: String, streaming: String) -> String? {
        guard let index = entries(inListing: listing)?.entries.map({ named($0.mode, $0.name) }),
              let read = readerEntries(inListing: unpacking), let stream = readerEntries(inListing: streaming) else {
            return "its listing could not be read"
        }
        let indexed = index.sorted()
        return read.sorted() == indexed && stream.sorted() == indexed ? nil : "its index and its entries name different files"
    }

    /// The number of file entries a ZIP's listing by `zipinfo -l` names: every entry but a folder (its mode "d", or its
    /// name ending in "/"), an entry of no stated type ("?", as Python's zipfile writes one) included; nil when the
    /// listing cannot be read. What the ZIP unpacks to must hold as many plain files (item 187, Claude's finding on
    /// 07b7134).
    static func fileEntries(inListing listing: String) -> Int? {
        entries(inListing: listing)?.entries.filter { !$0.mode.hasPrefix("d") && !$0.name.hasSuffix("/") }.count
    }

    /// Why what a ZIP unpacked to must not be read, checked after the listing it gave of itself (item 185, ds4agent-4):
    /// anything but plain files and folders (a link, a device, a pipe), more bytes than `largestUnpacked`, or (item 187,
    /// Claude's findings on 07b7134) a number of plain files other than `listedFiles`, the file entries of its listing:
    /// two entries for one file (the same name twice, or names a Mac takes as one), the first written over by the last; a
    /// "._" entry that macOS's unzip tool folds into the file before it as metadata, which it does whatever its options;
    /// or an entry not unpacked. Every name is walked, those beginning "._" too (`EvidenceBundle.names(in:)`). Nil when it
    /// may be read; nil for `listedFiles` leaves the count unchecked.
    static func refusal(ofUnpacked folder: URL, listedFiles: Int? = nil) -> String? {
        let manager = FileManager.default
        var bytes: Int64 = 0
        var files = 0
        var folders = [folder]
        while let current = folders.popLast() {
            guard let names = EvidenceBundle.names(in: current) else { return "what it unpacked to could not be read" }
            for name in names {
                // The attributes of a link are its own, never those of what it points to.
                guard let attributes = try? manager.attributesOfItem(atPath: current.appendingPathComponent(name).path) else {
                    return "what it unpacked to could not be read"
                }
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory?:
                    folders.append(current.appendingPathComponent(name, isDirectory: true))
                case .typeRegular?:
                    files += 1
                    bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    if bytes > largestUnpacked { return "it unpacked to more than \(largestUnpacked) bytes, more than a phone keeps of media" }
                default:
                    return "it unpacked to something that is not a plain file (\(name))"
                }
            }
        }
        if let listedFiles, files != listedFiles {
            return files < listedFiles
                ? "it unpacked to fewer files than it lists (\(files) of \(listedFiles)): two entries for one file, or an entry "
                    + "macOS took as another file's metadata"
                : "it unpacked to more files than it lists (\(files) of \(listedFiles))"
        }
        return nil
    }

    /// The entries of a ZIP's listing by `zipinfo -l`, each its mode and its name, and the bytes the listing says they
    /// unpack to; nil when the listing cannot be read.
    private static func entries(inListing listing: String) -> (entries: [(mode: String, name: String)], unpackedBytes: Int64)? {
        let lines = listing.split(separator: "\n").map(String.init)
        guard let headerIndex = lines.firstIndex(where: { $0.hasPrefix("Zip file size:") }),
              let declared = lines[headerIndex].split(separator: " ").last.flatMap({ Int($0) }),
              let totalsIndex = lines.lastIndex(where: { $0.range(of: #"^\d+ files?, \d+ bytes uncompressed"#, options: .regularExpression) != nil }),
              totalsIndex > headerIndex else {
            return nil
        }
        let entryLines = lines[(headerIndex + 1)..<totalsIndex]
        guard entryLines.count == declared else { return nil }
        var entries: [(mode: String, name: String)] = []
        for line in entryLines {
            let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
            guard fields.count == 10 else { return nil }
            entries.append((String(fields[0]), String(fields[9])))
        }
        let totals = lines[totalsIndex].split(separator: " ")
        guard totals.count > 3, let unpackedBytes = Int64(totals[2]) else { return nil }
        return (entries, unpackedBytes)
    }

    /// The entries of a ZIP as `bsdtar -tv` lists them (its mode, links, owner, group, size, three fields of date, then
    /// the name), each as `named(_:_:)` gives it; nil when a line cannot be read.
    private static func readerEntries(inListing listing: String) -> [String]? {
        var entries: [String] = []
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9 else { return nil }
            entries.append(named(String(fields[0]), String(fields[8])))
        }
        return entries
    }

    /// An entry as its kind and its name, the way the three readings of a ZIP are compared: a folder (its mode "d", or its
    /// name ending in "/"), a link ("l"), a file ("-", or "?" for no stated type), or another kind.
    private static func named(_ mode: String, _ name: String) -> String {
        let kind = mode.hasPrefix("d") || name.hasSuffix("/") ? "folder"
            : mode.hasPrefix("l") ? "link" : mode.hasPrefix("-") || mode.hasPrefix("?") ? "file" : "other"
        return kind + " " + name
    }

    // MARK: - Reading what is given

    /// The bundle's path and the root's, or nil when the arguments are not one bundle and at most one `--root FILE`.
    private static func parse(_ arguments: [String]) -> (String, String?)? {
        var bundle: String?
        var root: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--root" {
                guard root == nil, let file = rest.popFirst(), !file.hasPrefix("-") else { return nil }
                root = file
            } else if argument.hasPrefix("-") || bundle != nil {
                return nil
            } else {
                bundle = argument
            }
        }
        return bundle.map { ($0, root) }
    }

    /// A certificate's DER from a PEM or DER file; nil when it is neither, or not a certificate.
    private static func rootCertificate(at file: URL) -> Data? {
        guard let bytes = try? Data(contentsOf: file) else { return nil }
        let text = String(bytes: bytes, encoding: .utf8) ?? ""   // DER is not text
        let der = text.contains("-----BEGIN CERTIFICATE-----") ? Self.der(pem: text) : bytes
        guard let der, SecCertificateCreateWithData(nil, der as CFData) != nil else { return nil }
        return der
    }

    private static func der(pem: String) -> Data? {
        let body = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)
    }

    /// The ZIP `file`'s listing by `zipinfo -l`, its index read; nil when macOS cannot read it as a ZIP.
    static func listing(of file: URL) -> String? {
        guard let listing = tool("/usr/bin/zipinfo", ["-l", file.path]), listing.status == 0 else { return nil }
        return listing.output
    }

    /// How macOS's `bsdtar -tv` reads the ZIP `file` (item 187, codex-1 on fde1689): as it reads it to unpack it
    /// (`unpacking`), and front to back from each entry's own header (`streaming`), through a pipe, since given a file,
    /// even on its standard input, bsdtar reads the index; its ZIP reader's macOS extension off in both. Nil when either
    /// could not read it. The path is the shell's first argument, never part of its command.
    static func readings(of file: URL) -> (unpacking: String, streaming: String)? {
        let frontToBack = "/bin/cat -- \"$1\" | /usr/bin/bsdtar -t -v --options 'zip:!mac-ext' -f -"
        guard let unpacking = tool("/usr/bin/bsdtar", ["-t", "-v", "--options", "zip:!mac-ext", "-f", file.path]),
              unpacking.status == 0,
              let streaming = tool("/bin/sh", ["-c", frontToBack, "sh", file.path]), streaming.status == 0 else {
            return nil
        }
        return (unpacking.output, streaming.output)
    }

    /// Unpacks the ZIP `file` into the new folder `folder`, after checking its layout (item 187, codex-1 on 3096c70),
    /// reading its listing and checking that its three readings name the same entries (codex-1 on fde1689), with
    /// macOS's `bsdtar`, which refuses a path from the root or outside the folder and never writes through a link, then
    /// checks what it unpacked to against the listing (item 185, ds4agent-4; item 187); the reason it was not unpacked,
    /// or nil. Its ZIP reader's macOS extension is off: on, it would take a `__MACOSX/._` entry as a file's metadata and
    /// write no file for it, so what the entry holds would reach no check (item 187, codex-2 on 07b7134); off, it is a
    /// file the check reports. A "._" entry after the file it names, `bsdtar` folds into that file whatever its options:
    /// the count refuses that ZIP.
    private static func unpack(_ file: URL, into folder: URL) -> String? {
        // Its layout first, from its headers: one plain run of files, the same to every reader (codex-1 on 3096c70).
        if let reason = refusal(ofLayout: file) { return reason }
        guard let listing = Self.listing(of: file) else { return "it is not a ZIP that macOS can read" }
        if let reason = refusal(ofListing: listing) { return reason }
        guard let read = readings(of: file) else { return "macOS could not read it" }
        if let reason = refusal(ofListing: listing, unpacking: read.unpacking, streaming: read.streaming) { return reason }
        guard let listedFiles = fileEntries(inListing: listing) else { return "its listing could not be read" }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
              tool("/usr/bin/bsdtar", ["-x", "--options", "zip:!mac-ext", "-f", file.path, "-C", folder.path])?.status == 0 else {
            return "macOS could not unpack it"
        }
        return refusal(ofUnpacked: folder, listedFiles: listedFiles)
    }

    /// Runs the program at `path`; its exit status and what it printed, or nil when it could not be run.
    private static func tool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: printed, encoding: .utf8) ?? "")   // not text: read as nothing
    }

    /// The bundle's folder: `folder` itself when it holds the index, or its one folder that does, every name looked at.
    private static func bundleFolder(in folder: URL) -> URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.appendingPathComponent(EvidenceBundle.indexName).path) { return folder }
        let inside = (EvidenceBundle.names(in: folder) ?? []).map { folder.appendingPathComponent($0, isDirectory: true) }
        let holding = inside.filter { manager.fileExists(atPath: $0.appendingPathComponent(EvidenceBundle.indexName).path) }
        return holding.count == 1 ? holding[0] : nil
    }

    // MARK: - The check and its report

    /// What a pass shows and what it cannot, printed under PASS and only there (item 192's step 3, the owner's words of
    /// 2026-11-04: "approved"; item 198, 2026-11-05, and item 206, 2026-11-06: "wording approved"): SECURITY.md's "Evidence
    /// someone else can check", in short.
    static let passWords =
        "A pass shows: each signature was made by a key Apple certified for Malinois; the record, and each photo, clip "
        + "and trace in this ZIP, is byte for byte what was signed; and the ZIP accounts for every counter of the export's "
        + "key up to the export.\n"
        + "It cannot show: which iPhone made the ZIP or whose (any Malinois on any iPhone signs the same way), that the "
        + "phone's clock was right, what the event means, that the phone was not compromised, that the app that signed "
        + "was the App Store's (the KEYS line names each key's Apple environment, and from iOS 27 its kind of build), or "
        + "that every signature at a counter the phone's count went back over is here: a check sees the counters, not how "
        + "many times each was given out.\n"
        + "Both lists in full: SECURITY.md in Malinois's repository, \"Evidence someone else can check\".\n"

    /// Checks the bundle in `folder`, the folder given or the one a ZIP unpacked to, naming what was given (`given`)
    /// wherever the report names it: the bundle by its folder's name or, when its index lies at the root of a ZIP, by
    /// the ZIP's own name, never by the folder the ZIP unpacked to (item 187's deepseek-9).
    private static func check(_ folder: URL, given: URL, root: (der: Data, name: String), appIDHash: Data) -> Outcome {
        guard let bundle = bundleFolder(in: folder) else {
            return Outcome(text: "\(shown(given.path)) contains no Malinois evidence bundle (no \(EvidenceBundle.indexName)): nothing was checked.\n",
                           status: 2)
        }
        let name = shown(bundle.standardizedFileURL == folder.standardizedFileURL ? given.lastPathComponent : bundle.lastPathComponent)
        let report: EvidenceBundle.Report
        do {
            report = try EvidenceBundle.check(bundle, appIDHash: appIDHash, roots: [root.der])
        } catch {
            return Outcome(text: "\(name) is not a bundle this verifier reads (\(describe(error))): nothing was checked.\n",
                           status: 2)
        }
        // What lies beside the bundle's folder in what was given: a bundle accounts for every file (item 187, codex-1).
        guard let beside = beside(bundle, in: folder) else {
            return Outcome(text: "\(shown(given.path)) could not be listed: nothing was checked.\n", status: 2)
        }
        var text = "Malinois evidence check of \(name)\n"
        text += "Checked against \(root.name). Times are this Mac's, with their offset from UTC.\n"
        let problems = describe(report, beside: beside, into: &text)
        if problems.isEmpty {
            text += "\nPASS\n\n" + passWords   // what a pass shows and what it cannot (item 192's step 3)
            return Outcome(text: text, status: 0)
        }
        text += "\nPROBLEMS (\(problems.count)):\n" + problems.map { "  - \($0)\n" }.joined()
        return Outcome(text: text, status: 1)
    }

    /// What lies beside the bundle's folder in the folder given (`folder`, or the folder a ZIP unpacked to), each by its
    /// name, in order: nothing when that folder is the bundle's own; otherwise every other entry, those beginning "._"
    /// too, macOS's `.DS_Store` files apart (item 187, codex-1 on 09d997f). nil when the folder cannot be listed.
    private static func beside(_ bundle: URL, in folder: URL) -> (unlisted: [String], ignored: [String])? {
        guard bundle.standardizedFileURL != folder.standardizedFileURL else { return ([], []) }
        let manager = FileManager.default
        guard let names = EvidenceBundle.names(in: folder) else { return nil }
        var unlisted: [String] = []
        var ignored: [String] = []
        for name in names where name != bundle.lastPathComponent {
            // The attributes of a link are its own, never those of what it points to.
            let type = (try? manager.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.type] as? FileAttributeType
            if name == ".DS_Store", type == .typeRegular { ignored.append(name) } else { unlisted.append(name) }
        }
        return (unlisted.sorted(), ignored.sorted())
    }

    /// Writes the report into `text`, with what lies `beside` the bundle's folder, and returns what it found other than
    /// what a whole bundle shows.
    private static func describe(_ report: EvidenceBundle.Report, beside: (unlisted: [String], ignored: [String]),
                                 into text: inout String) -> [String] {
        var problems: [String] = []
        text += "The record shared: \(report.record.uuidString)\n"

        text += "\nKEYS\n"
        for check in report.keys {
            guard let key = check.key else {
                problems.append("key \(short(check.keyID)) is not certified: \(check.problem.map(describe) ?? "no reason given")")
                text += "  key \(short(check.keyID)): NOT certified\n"
                continue
            }
            text += "  key \(short(key.keyID)): certified by Apple for Malinois, as of \(time(key.judgedAt)); "
                + "\(key.environment.rawValue) environment\(channel(key.category, key.bundleVersion)); "
                + "its statement made \(time(ms: key.statement.signedAt)) by Malinois \(shown(key.statement.app))"
                + (key.statement.follows.map { ", following key \(short($0))" } ?? "") + "\n"
        }

        // Every key the export's or one it follows (item 190, codex-1): another phone's key, or one no restore led from;
        // where the export's chain stops at a key the bundle does not hold certified, in words true of any key it cannot
        // reach (deepseek-1 on 29d6501, deepseek-2 on b7702f5).
        for keyID in report.unrelatedKeys {
            let why = report.chainBreak.map {
                "cannot be tied to the export's key; the export's chain stops at key \(short($0)), "
                    + "which this bundle does not certify"
            } ?? "neither the export's key nor a key it follows"
            problems.append("key \(short(keyID)): \(why)")
        }

        problems += describeSignatures(report, into: &text)

        text += "\nCOUNTERS\n"
        for sequence in report.sequences {
            let missing = sequence.missing.isEmpty ? "none missing" : "missing: \(ranges(sequence.missing))"
            // Named by the key's own unkept statement: information, not a problem (item 188, ADR 0073).
            let unkept = sequence.unkept.isEmpty ? "" : "made by App Attest and not kept by the phone: \(ranges(sequence.unkept)); "
            text += "  key \(short(sequence.keyID)): \(ranges(EvidenceForm.counterRanges(sequence.counters))); retired: "
                + "\(sequence.retired.isEmpty ? "none" : ranges(sequence.retired)); \(unkept)\(missing)\n"
            if !sequence.missing.isEmpty { problems.append("key \(short(sequence.keyID)): counters missing: \(ranges(sequence.missing))") }
            // Two genuine signatures on one counter: App Attest's count went back (TestFlight 84: a forced restart; item 205, ADR
            // 0077). Only the key can make either, so neither is forged, which says nothing of what else the bundle held at that
            // counter: information, with what it costs a check (item 206).
            if !sequence.repeated.isEmpty {
                text += "  key \(short(sequence.keyID)): two signatures each at \(ranges(EvidenceForm.counterRanges(sequence.repeated))): the "
                    + "phone's count went back, as after a forced restart. At these counters a statement taken out, or cut down to its "
                    + "fingerprint, leaves no gap, even one the export names or one saying a record left the phone's log\n"
            }
            if !sequence.signedAgain.isEmpty { problems.append("key \(short(sequence.keyID)): signed again: \(sequence.signedAgain)") }
        }
        text += followedNotes(report)

        text += "\nTHE EXPORT\n"
        if let export = report.export {
            text += "  the record at revision \(export.revision), exported \(time(ms: export.signedAt)) by Malinois \(shown(export.app))\n"
            text += "  the statements it names as shown: \(namedAsShown(report))\n"
            text += "  the statements shown in full: " + (report.unnamed.isEmpty ? "all named by it\n" : "NOT all named by it\n")
        } else {
            text += "  none\n"
            problems.append("no export statement: where the bundle ends is not accounted for")
        }
        if !report.afterExport.isEmpty { problems.append("counters of the export's key after it: \(report.afterExport)") }
        if !report.unshown.isEmpty {
            problems.append("the export names statements the bundle does not show: "
                + report.unshown.map { "key \(short($0.keyID)) \(ranges($0.counters))" }.joined(separator: "; "))
        }
        if !report.unnamed.isEmpty {
            problems.append("statements shown in full that the export does not name: "
                + report.unnamed.map { "key \(short($0.keyID)) \(ranges($0.counters))" }.joined(separator: "; "))
        }

        text += "\nTHE RECORD'S REVISIONS: \(report.revisions.map { String($0.revision) }.joined(separator: ", "))\n"
        if !report.missingRevisions.isEmpty { problems.append("revisions missing: \(report.missingRevisions)") }
        if !report.revisionsInOrder { problems.append("the record's revisions are not in order") }

        text += "\nATTACHMENTS, against the last revision\n"
        for attachment in report.attachments {
            text += "  \(shown(attachment.name)): \(describe(attachment.outcome))\n"
            if attachment.outcome != .matches { problems.append("attachment \(shown(attachment.name)): \(describe(attachment.outcome))") }
        }
        text += earlierAttachments(report)

        for absence in report.absences {
            let records = absence.records.map(\.id.uuidString).joined(separator: ", ")
            problems.append("the phone signed that \(absence.records.count == 1 ? "a record" : "\(absence.records.count) records") "
                + "left its log other than by its limit: \(records)")
        }

        text += "\nTHE PHONE'S NOTES (written beside the signatures, not signed)\n"
            + (report.notes.isEmpty ? "  none\n" : report.notes.map { "  \(describe($0))\n" }.joined())
        problems += otherFiles(report, beside: beside, into: &text)
        problems += report.problems.map(describe)
        return problems
    }

    /// What the report says under THE EXPORT of the statements the export names: whether the bundle holds them all, and, at a
    /// counter where a fingerprint lies beside a statement shown in full, that the export names by counter and so does not
    /// say which of the two it means (item 206, Codex-1). Each key is named when more than one holds such a counter.
    private static func namedAsShown(_ report: EvidenceBundle.Report) -> String {
        let whole = report.unshown.isEmpty ? "all in the bundle" : "NOT all in the bundle"
        guard let first = report.ambiguous.first else { return whole }
        let places = report.ambiguous.count == 1 ? ranges(first.counters)
            : report.ambiguous.map { "\(ranges($0.counters)) of key \(short($0.keyID))" }.joined(separator: " and ")
        return whole + (report.unshown.isEmpty ? " by counter" : "") + "; at \(places) a second signature is only a fingerprint, "
            + "and the export does not say which of the two it names"
    }

    /// What the report says under SIGNATURES, and the problems it finds there: the signatures in the order the keys and
    /// counters prove, the oldest key first, whatever order the bundle's file gives its lines (item 190, codex-1), each
    /// line naming its key when there is more than one, since each key counts from 1. Keys outside the export's chain,
    /// problems of their own, come after it, as the heading then says (deepseek-6 on 29d6501).
    private static func describeSignatures(_ report: EvidenceBundle.Report, into text: inout String) -> [String] {
        var problems: [String] = []
        text += report.unrelatedKeys.isEmpty ? "\nSIGNATURES, in the phone's order\n"
            : "\nSIGNATURES, in the phone's order, then those of keys outside the export's chain\n"
        var rank: [Data: Int] = [:]
        for keyID in report.keyOrder + report.keys.map(\.keyID) where rank[keyID] == nil { rank[keyID] = rank.count }
        let ordered = report.signatures.sorted { first, second in
            func place(_ line: EvidenceBundle.SignatureCheck) -> (Int, UInt32, Int) {
                guard let entry = line.entry else { return (Int.max, UInt32.max, line.line) }
                return (rank[entry.keyID] ?? Int.max, entry.counter, line.line)
            }
            return place(first) < place(second)
        }
        var fingerprints = 0
        for line in ordered {
            guard let entry = line.entry else {
                problems.append("signature line \(line.line): \(line.problem.map(describe) ?? "no reason given")")
                continue
            }
            let counter = (report.keys.count > 1 ? "key \(short(entry.keyID)) " : "") + "counter \(entry.counter)"
            if let problem = line.problem { problems.append("\(counter): its statement \(describe(problem))") }
            switch entry.statement {
            case .record(let revision)?:
                var kind = "a record"
                if case .string(let change)? = revision.facts.first(where: { $0.key == "stateChange" })?.value { kind = "status \(shown(change))" }
                text += "  \(counter): \(revision.id == report.record ? "THE RECORD SHARED" : kind), revision "
                    + "\(revision.revision), signed \(time(ms: revision.signedAt)) by Malinois \(shown(revision.app)); attachments "
                    + (revision.attachments.isEmpty ? "none" : revision.attachments.map { shown($0.name) }.joined(separator: ", ")) + "\n"
            case .retention(let retention)?:
                let retired = retention.retired.map { "key \(short($0.keyID)) \(ranges($0.counters))" }.joined(separator: "; ")
                text += "  \(counter): retention statement, signed \(time(ms: retention.signedAt)), retiring \(retired)\n"
            case .export(let export)?:
                text += "  \(counter): EXPORT of the record at revision \(export.revision), signed "
                    + "\(time(ms: export.signedAt)) by Malinois \(shown(export.app))\n"
            case .absence(let absence)?:
                let named = absence.records.map { gone in
                    "\(gone.id.uuidString) (revision \(gone.revision)" + (gone.startDate.map { ", recorded \(time(ms: $0))" } ?? "") + ")"
                }
                text += "  \(counter): SIGNED RECORDS NO LONGER IN THE PHONE'S LOG, signed \(time(ms: absence.signedAt)) "
                    + "by Malinois \(shown(absence.app)): \(named.joined(separator: "; "))\n"
            case .unkept(let unkept)?:
                let count = unkept.counters.reduce(UInt64(0)) { $0 + UInt64($1.upperBound - $1.lowerBound) + 1 }
                text += "  \(counter): unkept statement, signed \(time(ms: unkept.signedAt)) by Malinois \(shown(unkept.app)): "
                    + (count == 1 ? "counter \(ranges(unkept.counters)) was" : "counters \(ranges(unkept.counters)) were")
                    + " made by App Attest and not kept by the phone\n"
            case .key?:
                problems.append("\(counter): a key's statement among the signatures")
            case nil:
                fingerprints += 1
            }
        }
        text += "  and \(fingerprints) more signature\(fingerprints == 1 ? "" : "s"), each shown only as the fingerprint of what it signed\n"
        return problems
    }

    /// What the report says under OTHER FILES, and the problems it finds there: a bundle is only what its layout names
    /// (item 187, codex-1 on 09d997f), so any other file, in it or beside its folder, is a problem; macOS's own
    /// `.DS_Store` files, which Finder leaves in a folder it shows, are named and not checked.
    private static func otherFiles(_ report: EvidenceBundle.Report, beside: (unlisted: [String], ignored: [String]),
                                   into text: inout String) -> [String] {
        text += "\nOTHER FILES\n"
        let other = report.unlisted.map(shown) + beside.unlisted.map { "\(shown($0)), beside its folder" }
        let finders = report.ignored.map(shown) + beside.ignored.map { "\(shown($0)), beside its folder" }
        if other.isEmpty, finders.isEmpty { text += "  none\n" }
        text += other.map { "  \($0): NOT part of the bundle\n" }.joined()
        text += finders.map { "  \($0): a file macOS's Finder keeps, not checked\n" }.joined()
        return other.map { "not part of the bundle: \($0)" }
    }

    /// What the report says under ATTACHMENTS after the last revision's: each attachment an earlier revision of the
    /// shared record signed that the last does not (the phone's storage limit removed a photo or clip, and the record was
    /// signed again without it), so a recipient learns it was there (item 185, ds4agent-3); and each the last signed under
    /// a name an earlier revision signed with other bytes, at the first such revision (a photo replaced under its name in
    /// iCloud, downloaded and signed again: item 190's codex-3), so a recipient learns the bytes changed. Neither is a
    /// problem: a thumbnail may change honestly. "none" when there is nothing at all.
    private static func earlierAttachments(_ report: EvidenceBundle.Report) -> String {
        let lastAttachments = report.revisions.last?.attachments ?? []
        let last = Set(lastAttachments.map(\.name))
        var signedIn: [String: Int64] = [:]
        var changedIn: [String: Int64] = [:]
        for revision in report.revisions.dropLast() {
            for attachment in revision.attachments {
                if !last.contains(attachment.name) {
                    signedIn[attachment.name] = revision.revision
                } else if changedIn[attachment.name] == nil,
                          lastAttachments.contains(where: { $0.name == attachment.name && $0.digest != attachment.digest }) {
                    changedIn[attachment.name] = revision.revision
                }
            }
        }
        // An attachment changed under its name is one the last revision signed, so among `report.attachments`.
        if report.attachments.isEmpty, signedIn.isEmpty { return "  none\n" }
        return signedIn.sorted { $0.key < $1.key }.map { name, revision in
            "  \(shown(name)): signed in revision \(revision) but not in the last revision, so not in the bundle\n"
        }.joined() + changedIn.sorted { $0.key < $1.key }.map { name, revision in
            "  \(shown(name)): signed with other bytes in revision \(revision); the bundle contains the last revision's\n"
        }.joined()
    }

    /// What the report says under COUNTERS of each key a later certified key says it follows (as after a restore from a
    /// backup): it may have signed after its last signature here, and nothing in a bundle can show it did not, so it is
    /// said, as a limit of the check rather than a problem (codex-2 on 73441cbe); for a key the bundle's index leaves out
    /// too, since a certified key names it (codex-2 on 417158fe). It says only what the later key says: another iPhone can
    /// make a key that follows this one, so nothing here shows both were on one iPhone (item 198's Fable-1).
    private static func followedNotes(_ report: EvidenceBundle.Report) -> String {
        let followed = Set(report.keys.compactMap { $0.key?.statement.follows })
        let last = Dictionary(report.sequences.map { ($0.keyID, $0.counters.max()) }, uniquingKeysWith: { first, _ in first })
        return followed.sorted { $0.lexicographicallyPrecedes($1) }.map { keyID in
            let made = last[keyID].flatMap { $0 }.map { "any signatures it made after counter \($0), its last here," }
                ?? "any signatures it made"
            return "  key \(short(keyID)): a later key says it follows it (as after a restore from a backup, though nothing "
                + "here shows both were on one iPhone), so \(made) cannot be accounted for\n"
        }.joined()
    }

    // MARK: - A sender's text

    /// A value from a bundle, a ZIP or a path as the report shows it: what it says, and nothing it could do. A sender
    /// chooses these, so a control character, a line break or a character that reorders a line shows as its escape
    /// (`\u{1B}`): it cannot act on the reader's terminal, or start a line of the report such as a PASS of its own
    /// (item 197's codex-2).
    static func shown(_ value: String) -> String { escaped(value) { _ in false } }

    /// The whole report as it leaves: the same, but for its own line breaks, so whatever a value's escaping missed can
    /// only be text.
    static func displayed(_ report: String) -> String { escaped(report) { $0 == "\n" } }

    private static func escaped(_ text: String, keeping kept: (Unicode.Scalar) -> Bool) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                if kept(scalar) {
                    result.append(scalar)
                } else {
                    result.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)
                }
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    // MARK: - Words

    static func describe(_ error: Error) -> String {
        (error as? EvidenceProblem).map(describe) ?? shown("\(error)")
    }

    static func describe(_ problem: EvidenceProblem) -> String {
        switch problem {
        case .unreadable(let why): "cannot be read: \(shown(why))"
        case .unknownFormat(let format): "is in another format (\(shown(format)))"
        case .formNotFixed: "is not in its fixed form"
        case .notAppAttest: "is not an Apple App Attest certification"
        case .chainNotTrusted: "Apple's certificate chain does not check out to the root"
        case .notForThisStatement: "Apple's certificate is for another statement"
        case .keyMismatch: "its parts do not name one key"
        case .otherApp: "the key belongs to another app than Malinois"
        case .counterNotZero: "its certification has a counter above zero"
        case .unknownEnvironment: "it names an environment Apple does not"
        case .formHashMismatch: "is not the one signed"
        case .signatureMismatch: "the signature is not the key's"
        case .notCertified: "signed by a key the bundle does not certify"
        case .fileMissing(let path): "\(shown(path)) is not in the bundle"
        case .formatNotAsHeld(let named):
            "the bundle names the format \(shown(named)), but what it contains is in "
                + (named == EvidenceBundle.format ? "\(EvidenceBundle.formatWithUnkept) (it contains an unkept statement)"
                   : "\(EvidenceBundle.format) (it contains no unkept statement)")
        }
    }

    private static func describe(_ outcome: EvidenceBundle.AttachmentOutcome) -> String {
        switch outcome {
        case .matches: "as signed"
        case .differs: "DIFFERENT from what was signed"
        case .notInBundle: "signed, but not in the bundle (gone from the phone, or left out)"
        case .notSigned: "in the bundle, but not signed"
        case .unreadable(let problem): describe(problem)
        }
    }

    private static func describe(_ note: EvidenceBundle.Note) -> String {
        switch note {
        case .keyLost(let key, let at):
            "App Attest no longer had key \(short(key)), as after a restore from a backup" + (at.map { ", noted \(time(ms: $0))" } ?? "")
        }
    }

    /// Apple's launch category for how the build was signed (iOS 27 and later), and its build number.
    static func channel(_ category: UInt32?, _ build: String?) -> String {
        let names: [UInt32: String] = [2: "TestFlight", 3: "development", 4: "App Store"]
        guard let category else { return "" }
        return "; a \(names[category] ?? "category \(category)") build" + (build.map { ", build \(shown($0))" } ?? "")
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
        return formatter.string(from: date)
    }

    private static func time(ms: Int64) -> String { time(Date(timeIntervalSince1970: Double(ms) / 1_000)) }

    private static func short(_ id: Data) -> String { String(EvidenceHash.hex(id).prefix(8)) + "…" }

    private static func ranges(_ ranges: [ClosedRange<UInt32>]) -> String {
        ranges.isEmpty ? "none" : ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)…\($0.upperBound)" }
            .joined(separator: ", ")
    }
}

/// A ZIP's headers, read for `MalinoisVerifier.refusal(ofLayout:)`: its end record, its index and each file's own
/// header and data descriptor; its files' bytes are never interpreted, though the end record's search reads the file's
/// tail (item 187, codex-1 on 3096c70).
private struct ZIPLayout {
    /// A way the ZIP leaves one plain layout, in words; `noEnd` when it has no end record, so is no ZIP at all.
    struct Problem: Error {
        let text: String
        static let noEnd = Problem(text: "no end record")
    }

    /// The kinds of extra field genuine ZIPs carry: the extended timestamp (0x5455) and Unix owner (0x7875) fields of
    /// the phone's ZIPs and of Info-ZIP's `zip`, and the older Unix field (0x5855) of `ditto` and the Finder's Compress.
    /// Another may change what a reader makes of a file: the Unicode Path field (0x7075) renames it for `bsdtar` alone
    /// (item 187, codex-3 on c68e3ec).
    private static let extraKinds: Set<Int> = [0x5455, 0x7875, 0x5855]

    /// An entry of the index: what the file's own header and data descriptor must repeat.
    private struct Entry {
        let flags: Int, method: Int, crc: UInt64, compressed: UInt64, size: UInt64, name: Data, offset: UInt64
    }

    let handle: FileHandle

    /// Throws the first way the ZIP leaves one plain layout.
    func check() throws {
        let size = try handle.seekToEnd()
        let end = try endRecord(size)
        try checkFiles(try index(at: end.indexOffset, size: end.indexSize, count: end.count), before: end.indexOffset)
    }

    /// `count` bytes from `offset`, all of them, indexed from 0.
    private func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw Problem(text: "it ends too soon") }
        return Data(data)
    }

    private static func u16(_ data: Data, _ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }

    private static func u32(_ data: Data, _ at: Int) -> UInt64 { UInt64(u16(data, at)) | UInt64(u16(data, at + 2)) << 16 }

    /// Throws unless `extra`, a file's extra fields in its own header or in the index, is one whole list of fields, each
    /// of a kind in `extraKinds` (item 187, codex-3 on c68e3ec).
    private static func checkExtras(_ extra: Data) throws {
        var at = 0
        while at < extra.count {
            guard at + 4 <= extra.count, at + 4 + u16(extra, at + 2) <= extra.count else {
                throw Problem(text: "a file's extra fields are not one list of fields")
            }
            guard extraKinds.contains(u16(extra, at)) else {
                throw Problem(text: "a file carries an extra field the check does not allow")
            }
            at += 4 + u16(extra, at + 2)
        }
    }

    /// The end record: the last signature whose record ends the file with its own comment, on one disk, no ZIP64, right
    /// after the index it names. A comment that holds the signature is refused: readers that take its last occurrence
    /// misread the ZIP, or refuse it (item 187, codex-2 on c68e3ec).
    private func endRecord(_ size: UInt64) throws -> (indexOffset: UInt64, indexSize: UInt64, count: Int) {
        guard size >= 22 else { throw Problem.noEnd }
        let tailLength = Int(min(size, 22 + 65_535))
        let start = size - UInt64(tailLength)
        let tail = try read(start, tailLength)
        let (u16, u32) = (Self.u16, Self.u32)
        let signature = Data([0x50, 0x4B, 0x05, 0x06])
        var last: Int?, found: Int?
        var before = tail.count
        while found == nil, let hit = tail.range(of: signature, options: .backwards, in: 0..<before) {
            let candidate = hit.lowerBound
            last = last ?? candidate
            if candidate + 22 <= tail.count, start + UInt64(candidate) + 22 + UInt64(u16(tail, candidate + 20)) == size {
                found = candidate
            }
            before = candidate
        }
        guard let last else { throw Problem.noEnd }
        guard let at = found else { throw last + 22 <= tail.count ? Problem(text: "bytes after its end") : Problem.noEnd }
        guard at == last else { throw Problem(text: "its comment contains an end record's signature") }
        let count = u16(tail, at + 10), indexSize = u32(tail, at + 12), indexOffset = u32(tail, at + 16)
        guard u16(tail, at + 4) == 0, u16(tail, at + 6) == 0, u16(tail, at + 8) == count, count != 0xFFFF,
              indexSize != 0xFFFF_FFFF, indexOffset != 0xFFFF_FFFF else { throw Problem(text: "a ZIP64 or split archive") }
        guard indexOffset + indexSize == start + UInt64(at), indexSize <= 1 << 24 else {
            throw Problem(text: "its index is not where its end record says")
        }
        return (indexOffset, indexSize, count)
    }

    /// The index: `count` entries that fill it exactly, each on the first disk, its extra fields of the kinds allowed.
    private func index(at offset: UInt64, size: UInt64, count: Int) throws -> [Entry] {
        let index = try read(offset, Int(size))
        let (u16, u32) = (Self.u16, Self.u32)
        var entries: [Entry] = []
        var at = 0
        for _ in 0..<count {
            guard at + 46 <= index.count, u32(index, at) == 0x0201_4B50, u16(index, at + 34) == 0,
                  at + 46 + u16(index, at + 28) <= index.count else { throw Problem(text: "its index is not one list of files") }
            let nameLength = u16(index, at + 28), extraStart = at + 46 + u16(index, at + 28)
            guard extraStart + u16(index, at + 30) <= index.count else { throw Problem(text: "its index is not one list of files") }
            try Self.checkExtras(index.subdata(in: extraStart..<(extraStart + u16(index, at + 30))))
            entries.append(Entry(flags: u16(index, at + 8), method: u16(index, at + 10), crc: u32(index, at + 16),
                                 compressed: u32(index, at + 20), size: u32(index, at + 24),
                                 name: index.subdata(in: (at + 46)..<(at + 46 + nameLength)), offset: u32(index, at + 42)))
            at += 46 + nameLength + u16(index, at + 30) + u16(index, at + 32)
        }
        guard at == index.count else { throw Problem(text: "its index is not one list of files") }
        return entries
    }

    /// The files: from the first byte, each where the one before it ends, its own header (and data descriptor)
    /// repeating its index entry; the index right after the last.
    private func checkFiles(_ entries: [Entry], before indexOffset: UInt64) throws {
        let (u16, u32) = (Self.u16, Self.u32)
        var at: UInt64 = 0
        for entry in entries {
            guard entry.offset == at else { throw Problem(text: "a file is not where the run of files puts it") }
            guard entry.flags & 1 == 0, entry.method == 0 || entry.method == 8, entry.compressed != 0xFFFF_FFFF,
                  entry.size != 0xFFFF_FFFF else { throw Problem(text: "a file is encrypted, ZIP64 or compressed another way") }
            let sizesAfter = entry.flags & 8 != 0
            // Stored with its sizes after its data, a file's end is a guess for a reader that reads front to back; empty,
            // with both its sizes 0, it has none to guess (deepseek-1 on c68e3ec).
            guard !(sizesAfter && entry.method == 0 && (entry.compressed > 0 || entry.size > 0)) else {
                throw Problem(text: "a stored file's sizes come after its data")
            }
            // A stored file is its bytes: readers that trust one size or the other read different bytes (deepseek-1).
            guard entry.method != 0 || entry.compressed == entry.size else { throw Problem(text: "a stored file's two sizes differ") }
            let header = try read(at, 30)
            let nameLength = u16(header, 26), extraLength = u16(header, 28)
            guard u32(header, 0) == 0x0403_4B50, u16(header, 6) == entry.flags, u16(header, 8) == entry.method,
                  try read(at + 30, nameLength) == entry.name else { throw Problem(text: "a file's own header names another file") }
            // A folder's entry holds nothing: bytes in it reach no check, and some readers show them (claude-1 on c68e3ec).
            guard entry.name.last != UInt8(ascii: "/") || (entry.compressed == 0 && entry.size == 0) else {
                throw Problem(text: "a folder's entry contains bytes")
            }
            try Self.checkExtras(try read(at + 30 + UInt64(nameLength), extraLength))
            let sizes = (u32(header, 14), u32(header, 18), u32(header, 22))
            guard sizes == (entry.crc, entry.compressed, entry.size) || (sizesAfter && sizes == (0, 0, 0)) else {
                throw Problem(text: "a file's sizes differ between its header and the index")
            }
            at += 30 + UInt64(nameLength + extraLength) + entry.compressed
            if sizesAfter { at += try descriptor(at, of: entry) }
        }
        guard at == indexOffset else { throw Problem(text: "bytes between its files and its index") }
    }

    /// The length of `entry`'s data descriptor at `at`, its signature optional; it must repeat the index's sizes.
    private func descriptor(_ at: UInt64, of entry: Entry) throws -> UInt64 {
        let skip: UInt64 = Self.u32(try read(at, 4), 0) == 0x0807_4B50 ? 4 : 0
        let fields = try read(at + skip, 12)
        guard (Self.u32(fields, 0), Self.u32(fields, 4), Self.u32(fields, 8)) == (entry.crc, entry.compressed, entry.size) else {
            throw Problem(text: "a file's data descriptor is not the index's")
        }
        return skip + 12
    }
}
