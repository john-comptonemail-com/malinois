//
//  EventLogView.swift
//  Malinois
//
//  PIN-gated list of tamper events with per-event exfiltration status.
//

import SwiftUI

struct EventLogView: View {
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var cloud: CloudExfiltrator
    @EnvironmentObject private var entitlements: ProEntitlements

    @ObservedObject private var enrollment = CloudEnrollment.shared
    @State private var isRetrying = false
    /// The held-event keys the last Hide covered (owner, 2026-10-11), read once per visit.
    @State private var hiddenHeldKeys = EventLogView.dismissedHeldKeys()

    private var unsyncedCount: Int { EventStore.unsyncedCount(in: eventStore.events) }

    struct SyncSummary {
        var retryableCount = 0
        var heldCount = 0
        var reasons: [CloudEnrollment.UploadHoldReason] = []
        /// One `heldBannerKey` per held event: what the held banner's Hide covers.
        var heldKeys: Set<String> = []
    }

    /// Shares the banner's eligibility/counting rules with regression tests.
    static func syncSummary(events: [Event], enrollment: CloudEnrollment) -> SyncSummary {
        var summary = SyncSummary()
        for event in events where !event.isMirrored && event.cloudSyncState != .synced {
            if let reason = enrollment.uploadHoldReason(for: event) {
                summary.heldCount += 1
                summary.heldKeys.insert(heldBannerKey(eventID: event.id, reason: reason))
                if !summary.reasons.contains(reason) { summary.reasons.append(reason) }
            } else {
                summary.retryableCount += 1
            }
        }
        return summary
    }

    /// What the held banner's Hide remembers for one held event: its ID and why it is held, so
    /// the same event held for a different reason counts as new.
    static func heldBannerKey(eventID: UUID, reason: CloudEnrollment.UploadHoldReason) -> String {
        "\(eventID.uuidString)|\(reason.rawValue)"
    }

    /// Pure (unit-tested; owner, 2026-10-11): whether the held-events banner shows. Hidden only
    /// while every event held now, with its current reason, was covered by the last Hide: a newly
    /// held event or a changed reason brings it back, and events leaving the held set do not.
    /// Hide changes only the banner; each event's badge and explanation stay.
    nonisolated static func heldBannerVisible(heldKeys: Set<String>, dismissedKeys: Set<String>) -> Bool {
        !heldKeys.isEmpty && !heldKeys.isSubset(of: dismissedKeys)
    }

    /// Where the held banner's Hide is remembered: this device's defaults, never iCloud.
    nonisolated static let heldBannerDismissedKey = "com.malinois.eventLog.heldBannerDismissed"

    /// The held-event keys covered by the last Hide; empty if Hide was never tapped.
    nonisolated static func dismissedHeldKeys(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: heldBannerDismissedKey) ?? [])
    }

    /// Records a Hide for exactly these held-event keys, replacing the previous one, so what is
    /// stored never outgrows the held set it covers.
    nonisolated static func rememberHeldBannerDismissal(_ keys: Set<String>, in defaults: UserDefaults = .standard) {
        defaults.set(keys.sorted(), forKey: heldBannerDismissedKey)
    }

    /// Pure (unit-tested; item 79): the banner's spinner shows for this screen's own request OR
    /// for a sweep anyone else started. The engine turns a second caller away at once while a
    /// sweep runs, so the screen's own flag alone dropped the spinner mid-sync.
    nonisolated static func bannerShowsSpinner(viewRetrying: Bool, sweepActive: Bool) -> Bool {
        viewRetrying || sweepActive
    }

    /// Pure (unit-tested; item 79): the banner's second line. iCloud being unavailable is the
    /// bigger news and keeps its instruction; otherwise, while the sweep waits out a throttle
    /// or an outage between passes, the banner says so — the count has stopped moving, and
    /// without a reason that reads as stuck.
    nonisolated static func bannerCaption(accountReady: Bool, sweepWaiting: Bool) -> String? {
        if !accountReady { return "Sign in to iCloud and confirm the app's CloudKit setup, then tap Retry." }
        if sweepWaiting { return "Uploads are paused for a moment. The rest will continue automatically." }
        return nil
    }

    var body: some View {
        let summary = Self.syncSummary(events: eventStore.events, enrollment: enrollment)
        return Group {
            if eventStore.events.isEmpty {
                ContentUnavailableView("No events",
                                       systemImage: "checkmark.shield",
                                       description: Text("No tamper events have been recorded."))
            } else {
                List {
                    if unsyncedCount > 0 {
                        // On the free tier these events never sync (cloud backup is Pro), so
                        // don't promise a sync or offer a no-op Retry — say plainly they were
                        // not uploaded (P-05; item 168's deepseek-2).
                        if entitlements.proActive {
                            if summary.retryableCount > 0 { syncBanner(count: summary.retryableCount) }
                            if Self.heldBannerVisible(heldKeys: summary.heldKeys, dismissedKeys: hiddenHeldKeys) {
                                heldBanner(summary)
                            }
                        } else {
                            freeTierBanner
                        }
                    }
                    ForEach(eventStore.events) { event in
                        NavigationLink {
                            EventDetailView(event: event)
                        } label: {
                            EventRow(event: event)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await retry() }
            }
        }
        .navigationTitle("Event Log")
        .navigationBarTitleDisplayMode(.inline)
        // Opportunistically re-sync anything stuck when the log opens.
        .task { await retry() }
        // Home's authenticated navigation binding marks records seen before each
        // open/close transition. Appearance callbacks can run later than the return
        // to Home; a late callback must not clear records received after the visit.
    }

    /// Offers Retry only for eligible local uploads; held evidence has a separate explanation.
    private func syncBanner(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(cloud.accountState.isReady ? .orange : .red).frame(width: 8, height: 8)
                Text(cloud.accountState.isReady
                     ? "\(count) event(s) not yet synced to iCloud"
                     : "iCloud unavailable - \(cloud.accountState.displayName)")
                    .font(.caption)
                Spacer()
                if Self.bannerShowsSpinner(viewRetrying: isRetrying, sweepActive: engine.pendingSweepActive) {
                    ProgressView()
                } else {
                    Button("Retry") { Task { await retry() } }
                        .font(.caption.weight(.semibold))
                }
            }
            if let caption = Self.bannerCaption(accountReady: cloud.accountState.isReady,
                                                sweepWaiting: engine.pendingSweepWaiting) {
                Text(caption)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .listRowSeparator(.hidden)
    }

    /// Held evidence is retained, not queued for Retry. Details distinguish account holds
    /// from enrollment/storage problems without exposing account identifiers. Hide covers the
    /// events held now (`heldBannerVisible`); each event keeps its own badge and explanation.
    private func heldBanner(_ summary: SyncSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label("\(summary.heldCount) event(s) kept on this device", systemImage: "internaldrive")
                    .font(.caption)
                Spacer()
                Button("Hide") {
                    Self.rememberHeldBannerDismissal(summary.heldKeys)
                    hiddenHeldKeys = summary.heldKeys
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            ForEach(summary.reasons, id: \.self) { reason in
                Text(reason.explanation).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .listRowSeparator(.hidden)
    }

    /// Free-tier variant of the sync banner: cloud backup is Pro, so Malinois uploads none of these
    /// events. No Retry (it would no-op behind the `proActive` guard) — just the honest state.
    private var freeTierBanner: some View {
        let text = Self.freeTierBannerText(count: unsyncedCount)
        return HStack(spacing: 6) {
            Circle().fill(.secondary).frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .reportedOnScreen(text)   // read as shown by item 168's tests
            Spacer()
        }
        .listRowSeparator(.hidden)
    }

    /// The free-tier banner's words for `count` events: not uploaded, rather than "stay on this device", which the
    /// iPhone's own backups can make untrue (item 168's deepseek-2).
    static func freeTierBannerText(count: Int) -> String {
        "iCloud backup is Pro - \(count) event(s) not uploaded"
    }

    private func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        // Push what's pending, then pull anything this device hasn't seen. The pull is the
        // user-initiated half of BACKLOG 9b, and it doubles as the restore path after a
        // reinstall: the local log starts empty, so everything mirrored comes back.
        await engine.retryPendingSync()
        // The restore path: ask for as much as the local log can hold, not one page.
        await engine.syncFromCloud(limit: EventStore.maxEvents)
        isRetrying = false
    }
}

struct EventRow: View {
    let event: Event
    @ObservedObject private var enrollment = CloudEnrollment.shared
    @EnvironmentObject private var entitlements: ProEntitlements

    private var holdReason: CloudEnrollment.UploadHoldReason? {
        entitlements.proActive ? enrollment.uploadHoldReason(for: event) : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(event.startDate, format: .dateTime.month().day().hour().minute().second())
                    .font(.subheadline.weight(.semibold))
                Text(event.sensorSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if event.ownerAttributed == true {
                        Label("You (disarm)", systemImage: "person.fill.checkmark")
                            .foregroundStyle(.secondary)
                    }
                    // A mirrored copy is a claim about another device, not evidence this
                    // device witnessed — it must never read as first-hand. Only the facts and
                    // thumbnail travel automatically; the full capture can be pulled on demand
                    // from the event's detail view (34.B1).
                    if let source = event.sourceDevice {
                        Label(source, systemImage: "icloud.and.arrow.down")
                            .foregroundStyle(.blue)
                    }
                    if !event.durationSummary.isEmpty {
                        Text(event.durationSummary)
                    }
                    syncBadge
                }
                .font(.caption2)
                if holdReason != nil {
                    Text("Kept on this device · Open for details")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        // Events captured while you were disarming are your own handling — de-emphasize
        // them so they don't read as tampers.
        .opacity(event.ownerAttributed == true ? 0.5 : 1)
    }

    private var isVideo: Bool { event.mediaFilename?.lowercased().hasSuffix(".mov") ?? false }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = event.thumbnailData,
           let ui = BoundedImageDecoder.image(from: data, maxPixelSize: BoundedImageDecoder.thumbnailDisplayPixels,
                                              maxSourcePixels: BoundedImageDecoder.maxThumbnailSourcePixels) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if isVideo {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: Self.placeholderIcon(for: event.stateChange)).foregroundStyle(.secondary))
        }
    }

    /// Icon for an event with no captured image — a lock for a monitoring state change,
    /// otherwise the "no frame" camera glyph. Static so a test can read it (item 144 (g)).
    static func placeholderIcon(for stateChange: String?) -> String {
        switch stateChange {
        case "armed":    return "lock.fill"
        case "disarmed": return "lock.open.fill"
        case "gaLifted": return "lock.slash"
        case "armingCancelled":   return "xmark.shield"
        case "armingInterrupted": return "exclamationmark.shield"
        case "thermalSerious":    return "thermometer.medium"   // item 38
        case "thermalCritical":   return "thermometer.high"
        case "soundUnavailable":  return "mic.slash"   // item 105, F-09
        case "soundRestored":     return "mic"
        case "motionStalled":     return SensorType.motion.iconName   // item 144 (g)
        case "reinstalled":       return "arrow.down.app"   // item 148's 5
        case "pinChanged":        return "key.fill"   // item 153's MAL-03
        case "guidedAccessEnded": return "lock.trianglebadge.exclamationmark"   // item 153's MAL-05
        case "unsyncedRemoved":   return "tray.full"   // item 114
        case "reArmSkipped":      return "exclamationmark.arrow.triangle.2.circlepath"   // item 153's MAL-10, Home's notice's symbol
        case "settingsReset":     return "arrow.counterclockwise"   // codex-10
        case "backupOff":         return "icloud.slash"   // item 115
        case "backupOn":          return "icloud"
        case let kind? where Event.isProtectionChangeKind(kind): return "slider.horizontal.3"   // item 91; step 22's seven
        case let kind? where Event.clockChangeSeconds(kind: kind) != nil: return "clock.badge.exclamationmark"   // item 113
        case let kind? where Event.resumedSeconds(kind: kind) != nil: return "eye"   // item 153's MAL-06
        case let kind? where Event.sirenElsewhereDevice(kind: kind) != nil: return "headphones"   // 1.8.2's step 26
        default:         return "camera.metering.none"
        }
    }

    @ViewBuilder
    private var syncBadge: some View {
        // Arm/disarm rows carry this badge too. They were exempt until 1.1, on the reasoning
        // that a state record was "a local audit entry, not evidence awaiting upload" — true
        // until BACKLOG 8 started pushing the audit trail, and misleading ever since. A disarm
        // record that never left the device is the most consequential upload failure the owner
        // can have: the cloud copy is the entire reason that record survives an attacker who
        // deletes the app, and silence about it read as success.
        let color: Color = {
            switch event.cloudSyncState {
            case .synced:    return .green
            case .pending:   return .orange
            case .localOnly: return .red
            }
        }()
        Label(holdReason == nil ? event.cloudSyncState.displayName : "Local only", systemImage: "icloud")
            .foregroundStyle(holdReason == nil ? color : .secondary)
    }
}
