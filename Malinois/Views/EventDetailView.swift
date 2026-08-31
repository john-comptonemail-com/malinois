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
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var entitlements: ProEntitlements
    @State private var showShare = false
    @State private var downloading = false
    @State private var downloadFoundNothing = false

    /// The live copy from the store — the view renders THIS, so a download that attaches
    /// media (34.B1) reflows the screen the moment the store updates. Falls back to the
    /// passed value for an event no longer in the store.
    private var current: Event { eventStore.events.first { $0.id == event.id } ?? event }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button { showShare = true } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share evidence")
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }

    /// Text summary + the media file (if present) to hand to the system share sheet
    /// — for sending evidence to building security, police, or a group chat.
    private var shareItems: [Any] {
        // The formatted value already carries its own "at" ("Aug 3, 2026 at 2:15 PM"), so the
        // sentence takes "on" — otherwise it reads "tampering at … at …".
        let timestamp = current.startDate.formatted(date: .abbreviated, time: .shortened)
        var text = "Malinois detected tampering on \(timestamp) — \(current.sensorSummary) triggered."
        if !current.durationSummary.isEmpty { text += " Recording: \(current.durationSummary)." }
        var items: [Any] = [text]
        // Share BOTH captures for a "Both" event — the secondary is often the face shot
        // you'd most want to hand to security, and dropping it silently is a footgun (V-08).
        for url in [eventStore.mediaURL(for: current), eventStore.secondaryMediaURL(for: current)] {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                items.append(url)
            }
        }
        return items
    }

    @ViewBuilder
    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = captureLabel(camera: current.primaryCamera, duration: current.primaryDuration) {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            EvidenceMediaView(url: eventStore.mediaURL(for: current),
                              fallbackThumbnail: current.thumbnailData)
            if current.secondaryMediaFilename != nil {
                if let label = captureLabel(camera: current.secondaryCamera, duration: current.secondaryDuration) {
                    Text(label).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                EvidenceMediaView(url: eventStore.secondaryMediaURL(for: current),
                                  fallbackThumbnail: nil)
            }
            // A capture the storage cap had to discard before it ever uploaded exists
            // nowhere any more — say so plainly, and never offer a download that is
            // guaranteed to find nothing (34.H5).
            if current.mediaDiscarded == true {
                Label("The full capture was discarded by the storage cap before it could upload.",
                      systemImage: "externaldrive.badge.xmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            // The retrieval half of the Pro backup promise (34.B1): a restored or
            // byte-pruned event has no local media, but its full capture may still be in
            // iCloud — reachable by deterministic record ID, so this needs no schema work.
            if current.mediaFilename == nil, !current.isStateChange, entitlements.proActive,
               current.mediaDiscarded != true {
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
                Button {
                    Task {
                        downloading = true
                        downloadFoundNothing = false
                        let landed = await engine.downloadFullEvidence(for: current.id)
                        downloading = false
                        downloadFoundNothing = !landed
                    }
                } label: {
                    Label("Download full evidence from iCloud", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if downloadFoundNothing {
                    Text("Nothing came back — the full capture may not be in iCloud, or iCloud isn't reachable.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
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
            HStack {
                Text("Exfiltration").foregroundStyle(.secondary)
                Spacer()
                Label(current.cloudSyncState.displayName, systemImage: "icloud")
                    .foregroundStyle(syncColor)
            }
            .font(.subheadline)
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
            } else if let fallbackThumbnail, let ui = UIImage(data: fallbackThumbnail) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        Text("Thumbnail only — full media not on this device")
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
        // Read the full-res still off the main thread; decode on return.
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        if let data { image = UIImage(data: data) }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.15))
            .frame(height: 220)
            .overlay(Image(systemName: "camera.metering.none")
                .font(.largeTitle).foregroundStyle(.secondary))
    }
}

/// Thin wrapper around `UIActivityViewController` for exporting an event's
/// evidence (text summary + media file) via the system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
