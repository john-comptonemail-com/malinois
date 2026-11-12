//
//  EventDetailView.swift
//  Malinois
//
//  Full evidence for a single event: the captured still, sensor traces, and the
//  exfiltration status.
//

import SwiftUI
import AVKit

struct EventDetailView: View {
    let event: Event
    /// A record read from a set-aside log (item 122): shown as that log has it, read only, with no Share of its own (its
    /// log's screen shares the whole file), no download and nothing asked of iCloud; and nothing said of an upload, since
    /// it never uploads: no hold, no "Last heard from", and its iCloud row says where it was (item 213), or, for a record
    /// the event log also has, is not shown (item 214).
    var setAside = false
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var entitlements: ProEntitlements
    @Environment(\.evidenceExporter) private var exporter
    @ObservedObject private var enrollment = CloudEnrollment.shared

    /// Why this record's upload is held, on Pro; none for a set-aside record, which never uploads (item 213).
    private var holdReason: CloudEnrollment.UploadHoldReason? {
        guard !setAside, entitlements.proActive else { return nil }
        return enrollment.uploadHoldReason(for: current)
    }

    /// A set-aside record the event log also has (item 214's fable-4): its screen shows no iCloud row, since the event
    /// log's row for it has the one that is true now. Read from the event log as it is, as the set-aside log's mark is.
    private var alsoInLog: Bool { setAside && eventStore.events.contains { $0.id == event.id } }

    /// The sheet Share opened, with what it sends, fixed when it opens (item 90, phase 4). The sheet is handed these, not
    /// what the screen held when SwiftUI last drew it: the first sheet a screen opened was handed the screen's first
    /// drawing, without the bundle (the device check of 2026-10-31).
    @State private var sharing: ShareRequest?
    /// While Share asks whether this phone signed the record, before its sheet opens.
    @State private var openingShare = false
    /// The evidence bundle the open sheet offers (item 90, phase 4), made only when the owner picks where to send it,
    /// and removed once the sheet is gone.
    @State private var bundleItem: EvidenceBundleItem?
    /// After a share that went without the signed evidence ZIP, why (item 200): shown until the owner leaves the screen,
    /// and cleared when Share opens again.
    @State private var shareNote: String?
    @State private var downloading = false
    @State private var downloadFoundNothing = false
    /// A download ran but some iCloud slots went unchecked (R3-3) — keeps the download
    /// section up for a retry even after a capture landed.
    @State private var downloadIncomplete = false
    /// A capture iCloud gave is not the one this iPhone signed for the record, and was not added (item 190's A4, its
    /// download half; the owner's wording, 2026-11-04: "a, approved").
    @State private var downloadRefused = false
    /// Item 52: when the phone that armed this watch was last heard from (an arm record from
    /// another phone, on Pro); nil until the reader answers.
    @State private var lastHeard: LastHeard?

    /// The live copy from the store — the view renders THIS, so a download that attaches
    /// media (34.B1) reflows the screen the moment the store updates. Falls back to the
    /// passed value for an event no longer in the store. A set-aside log's record is shown
    /// as that log has it, even when the log has it too (item 122).
    private var current: Event { setAside ? event : (eventStore.events.first { $0.id == event.id } ?? event) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let shareNote {
                    Label(shareNote, systemImage: "doc.zipper")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                mediaSection

                metadata

                if !current.motionTrace.isEmpty {
                    traceSection("Motion (user-accel, g)", values: current.motionTrace, color: .blue)
                }
                if !current.audioTrace.isEmpty {
                    traceSection("Sound (dBFS)", values: current.audioTrace, color: .purple)
                }
            }
            .padding()
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !setAside {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: startShare) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share evidence")
                    .reportedAction("Share evidence", startShare)
                }
            }
        }
        .sheet(item: $sharing, onDismiss: finishShare) { request in
            ShareSheet(items: request.items) { destination, completed in
                // The sheet's own end (item 200): the bundle and the reason the request was opened with, whichever of
                // this and the sheet's dismissal comes first.
                shareNote = ShareNote.line(readiness: request.readiness, completed: completed, destination: destination,
                                           made: request.bundle?.madeForTheDestination, mirrored: current.isMirrored)
            }
        }
        .task(id: current.id) {   // item 52
            guard Heartbeat.showsLastHeard(for: current, pro: entitlements.proActive, setAside: setAside) else { return }
            lastHeard = await engine.lastHeard(session: current.id)
        }
    }

    /// What Share hands the system sheet: the sentence, each photo or clip still on the phone, then the evidence bundle
    /// of a record this phone signed (item 90, phase 4), made only when the owner picks where to send it.
    static func shareItems(sentence: String, media: [URL?], bundle: EvidenceBundleItem?) -> [Any] {
        var items: [Any] = [sentence]
        // Share BOTH captures for a "Both" event — the secondary is often the face shot
        // you'd most want to hand to security, and dropping it silently is a footgun (V-08).
        for url in media {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                items.append(url)
            }
        }
        if let bundle { items.append(bundle) }
        return items
    }

    /// Text summary + the media file (if present) to hand to the system share sheet
    /// — for sending evidence to building security, police, or a group chat — then `bundle`.
    private func shareItems(bundle: EvidenceBundleItem?) -> [Any] {
        // The formatted value already carries its own "at" ("Aug 3, 2026 at 2:15 PM"), so the
        // sentence takes "on" — otherwise it reads "tampering at … at …".
        let timestamp = current.startDate.formatted(date: .abbreviated, time: .shortened)
        return Self.shareItems(sentence: current.shareSentence(timestamp: timestamp),
                               media: [eventStore.mediaURL(for: current), eventStore.secondaryMediaURL(for: current)],
                               bundle: bundle)
    }

    private func startShare() { Task { await openShare() } }

    /// Opens the share sheet: for a record this phone signed, with its evidence bundle as one more item, made only when
    /// the owner picks where to send it (item 90, phase 4). A second tap meanwhile opens nothing more.
    private func openShare() async {
        guard sharing == nil, !openingShare else { return }
        openingShare = true
        defer { openingShare = false }
        let offer = await EvidenceBundleItem.offer(of: current, log: eventStore.events, exporter: exporter)
        bundleItem = offer.item
        shareNote = nil
        sharing = ShareRequest(items: shareItems(bundle: offer.item), bundle: offer.item, readiness: offer.readiness)
    }

    /// Once the sheet is gone: its bundle removed off the main thread, which never waits on one still being made.
    private func finishShare() {
        guard let item = bundleItem else { return }
        bundleItem = nil
        Task.detached { item.finish() }
    }

    /// The files the media section shows, the first camera's and the second's: a live event's as its Share and its
    /// upload have them, a set-aside record's through the store's own two for it, which take nothing through a media
    /// folder that is a link (ADR 0078's decision 5; item 226's Codex-5).
    static func shownMedia(of event: Event, in store: EventStore, setAside: Bool) -> (primary: URL?, secondary: URL?) {
        setAside ? (store.setAsideMediaURL(for: event), store.setAsideSecondaryMediaURL(for: event))
                 : (store.mediaURL(for: event), store.secondaryMediaURL(for: event))
    }

    @ViewBuilder
    private var mediaSection: some View {
        let shown = Self.shownMedia(of: current, in: eventStore, setAside: setAside)
        VStack(alignment: .leading, spacing: 8) {
            if let label = captureLabel(camera: current.primaryCamera, duration: current.primaryDuration) {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            EvidenceMediaView(url: shown.primary,
                              fallbackThumbnail: current.thumbnailData)
            if current.secondaryMediaFilename != nil {
                if let label = captureLabel(camera: current.secondaryCamera, duration: current.secondaryDuration) {
                    Text(label).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                EvidenceMediaView(url: shown.secondary,
                                  fallbackThumbnail: nil)
            }
            // The storage cap removed the local files, and none remain in iCloud: before their first upload or after
            // a detected cloud loss. Say so without claiming an upload never happened, and offer no empty download.
            if current.mediaDiscarded == true {
                Label("The storage cap removed the local full capture. No copy is available in iCloud.",
                      systemImage: "externaldrive.badge.xmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            // Original per-camera coverage remains visible alongside successful evidence.
            // Only a whole-capture failure can describe an attached photo as the bounded retry.
            ForEach(current.captureFailureMessages, id: \.self) { message in
                Label(message, systemImage: "camera.badge.ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            // The retrieval half of the Pro backup promise (34.B1): a restored or
            // byte-pruned event has no local media, but its full capture may still be in
            // iCloud — reachable by deterministic record ID, so this needs no schema work.
            // Offered while a file the record names is not here, on every visit (item 167's A2:
            // a download that brought the front of a Both capture whose rear had not uploaded
            // yet), and not once every named file is (codex-5: a capture whose only file is its
            // rear); a copy that names none keeps the old rule. An INCOMPLETE download (R3-3:
            // some slots went unchecked) keeps the section up even after a capture landed, so
            // the owner can retry for the rest. Offered only where a copy can exist (item 118):
            // never after a capture that never happened, or for this iPhone's events that never
            // uploaded.
            if !setAside, current.mayLackAFileHere || downloadIncomplete, !current.isStateChange,
               entitlements.proActive, current.mediaDiscarded != true, current.fullCaptureMayBeInICloud {
                downloadSection
            }
        }
    }

    @ViewBuilder
    private var downloadSection: some View {
        if downloading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Downloading from iCloud…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: startDownload) {
                    Label { Text("Download full evidence from iCloud").reportedOnScreen("Download full evidence from iCloud") }
                          icon: { Image(systemName: "icloud.and.arrow.down") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .reportedAction("Download full evidence from iCloud", startDownload)
                if downloadRefused {
                    Text("A capture in iCloud differs from the one this iPhone recorded, so it wasn't added - iCloud's copy is unchanged.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .reportedOnScreen("A capture in iCloud differs from the one this iPhone recorded, so it wasn't added - iCloud's copy is unchanged.")
                }
                if downloadFoundNothing {
                    Text("Nothing came back - the full capture may not be in iCloud, or iCloud isn't reachable.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .reportedOnScreen("Nothing came back - the full capture may not be in iCloud, or iCloud isn't reachable.")
                } else if downloadIncomplete {
                    // Landed something, but a slot went unchecked (R3-3): say so instead
                    // of presenting a partial download as the whole story.
                    Text("A capture downloaded, but not everything could be checked - try again for the rest.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .reportedOnScreen("A capture downloaded, but not everything could be checked - try again for the rest.")
                }
            }
        }
    }

    /// Downloads the event's full capture from iCloud and says how it went: a capture that is not the one this iPhone
    /// signed, not added (item 190's A4); nothing came back; or not everything could be checked.
    private func startDownload() {
        Task {
            downloading = true
            downloadRefused = false
            downloadFoundNothing = false
            downloadIncomplete = false
            let outcome = await engine.downloadFullEvidence(for: current.id)
            downloading = false
            downloadRefused = outcome.refused
            downloadFoundNothing = !outcome.landed && !outcome.refused   // something came back: not "nothing came back"
            downloadIncomplete = !outcome.complete
        }
    }

    /// "Front camera · 5.0s" / "Rear camera" style label for a capture.
    private func captureLabel(camera: String?, duration: Double?) -> String? {
        let name: String? = camera == "front" ? "Front camera"
                          : camera == "rear"  ? "Rear camera" : nil
        switch (name, duration) {
        case let (n?, d?): return "\(n) · \(String(format: "%.1fs", d))"
        case let (n?, nil): return n
        case let (nil, d?): return String(format: "Recording · %.1fs", d)
        default: return nil
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Time", current.startDate.formatted(date: .abbreviated, time: .standard))
            row(current.durationSummary.isEmpty ? "Duration" : "Recording",
                current.durationSummary.isEmpty ? String(format: "%.2f s", current.duration) : current.durationSummary)
            row("Triggered by", current.sensorSummary)
            if let thermal = current.thermalStateSummary {
                row("Phone temperature", thermal)   // item 38, choice 3
            }
            if Heartbeat.showsLastHeard(for: current, pro: entitlements.proActive, setAside: setAside) {
                row("Last heard from", Heartbeat.lastHeardText(lastHeard))
            }
            if CloudSyncState.showsBadge(setAside: setAside, alsoInLog: alsoInLog) {
                HStack {
                    Text("Exfiltration").foregroundStyle(.secondary)
                    Spacer()
                    let badge = current.cloudSyncState.badge(held: holdReason != nil, setAside: setAside)
                    Label(badge, systemImage: "icloud")
                        .foregroundStyle(holdReason == nil ? syncColor : .secondary)
                        .reportedOnScreen(badge)
                }
                .font(.subheadline)
            }
            if let holdReason {
                Text(holdReason.explanation)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private func traceSection(_ title: String, values: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Sparkline(values: values, color: color)
                .frame(height: 80)
                .padding(.vertical, 4)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var syncColor: Color {
        // It never uploads (item 213), and its badge is what the file recorded, never a state checked now, so never
        // green (item 227's DS-2).
        if setAside { return .secondary }
        switch current.cloudSyncState {
        case .synced:    return .green
        case .pending:   return .orange
        case .localOnly: return .red
        }
    }
}

/// A minimal line chart for a sensor trace.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let range = max(maxV - minV, 0.0001)
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = values.count > 1
                        ? geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        : 0
                    let y = geo.size.height * (1 - CGFloat((v - minV) / range))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.06)))
        }
    }
}

/// Renders one piece of evidence: a playable video for a `.mov`, an image for a
/// still, or a thumbnail / placeholder fallback.
struct EvidenceMediaView: View {
    let url: URL?
    let fallbackThumbnail: Data?

    /// The words over a thumbnail shown in place of a photo or clip that is not on this phone.
    static let thumbnailOnly = "Thumbnail only - full media not on this device"

    // Loaded once per url (via .task) rather than rebuilt on every body pass — a
    // fresh AVPlayer per render restarted playback, and reading the still on the
    // main thread hitched the scroll.
    @State private var player: AVPlayer?
    @State private var image: UIImage?

    private var isVideo: Bool { url?.pathExtension.lowercased() == "mov" }

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if mediaPresent {
                // Present but still decoding — a neutral placeholder, never the
                // "not on this device" badge (which would flash misleadingly).
                placeholder
            } else if let fallbackThumbnail,
                      let ui = BoundedImageDecoder.image(from: fallbackThumbnail,
                                                         maxPixelSize: BoundedImageDecoder.thumbnailDisplayPixels,
                                                         maxSourcePixels: BoundedImageDecoder.maxThumbnailSourcePixels) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        Text(Self.thumbnailOnly)
                            .reportedOnScreen(Self.thumbnailOnly)
                            .font(.caption2)
                            .padding(6)
                            .background(.ultraThinMaterial)
                    }
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    /// Whether the full-res media file actually exists on this device.
    private var mediaPresent: Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func load() async {
        player = nil; image = nil
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        if isVideo {
            player = AVPlayer(url: url)
            return
        }
        // Read and decode the full-res still off the main thread, within the decoder's bounds
        // (item 105, F-10): an image over its pixel cap keeps the neutral placeholder.
        image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return BoundedImageDecoder.image(from: data, maxPixelSize: BoundedImageDecoder.fullDisplayPixels)
        }.value
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.15))
            .frame(height: 220)
            .overlay(Image(systemName: "camera.metering.none")
                .font(.largeTitle).foregroundStyle(.secondary))
    }
}

/// What one share sheet sends, fixed when Share opens it (item 90, phase 4), with its bundle and, when it has none, the
/// signer's reason, for the line after the share (item 200).
struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]
    var bundle: EvidenceBundleItem?
    var readiness: EvidenceExportReadiness?
}

/// Thin wrapper around `UIActivityViewController` for exporting an event's
/// evidence (text summary + media file) via the system share sheet. `ended` hears the sheet's end: the destination
/// picked, and whether the share completed (false when it was cancelled; item 200).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var ended: @MainActor (UIActivity.ActivityType?, Bool) -> Void = { _, _ in }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        #if DEBUG
        context.environment.onScreenRecorder?.handed(items)   // what a test that lays out the screen reads
        #endif
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let ended = ended
        controller.completionWithItemsHandler = { destination, completed, _, _ in
            MainActor.assumeIsolated { ended(destination, completed) }   // UIKit calls it on the main thread
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
