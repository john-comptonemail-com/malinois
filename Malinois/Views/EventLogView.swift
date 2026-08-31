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

    @State private var isRetrying = false

    private var unsyncedCount: Int { EventStore.unsyncedCount(in: eventStore.events) }

    var body: some View {
        Group {
            if eventStore.events.isEmpty {
                ContentUnavailableView("No events",
                                       systemImage: "checkmark.shield",
                                       description: Text("No tamper events have been recorded."))
            } else {
                List {
                    if unsyncedCount > 0 {
                        // On the free tier these events never sync (cloud backup is Pro), so
                        // don't promise a sync or offer a no-op Retry — say plainly they're
                        // kept on-device (P-05).
                        if entitlements.proActive { syncBanner } else { freeTierBanner }
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
    }

    /// A banner explaining iCloud status and offering a manual re-sync.
    private var syncBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(cloud.accountState.isReady ? .orange : .red).frame(width: 8, height: 8)
                Text(cloud.accountState.isReady
                     ? "\(unsyncedCount) event(s) not yet synced to iCloud"
                     : "iCloud unavailable — \(cloud.accountState.displayName)")
                    .font(.caption)
                Spacer()
                if isRetrying {
                    ProgressView()
                } else {
                    Button("Retry") { Task { await retry() } }
                        .font(.caption.weight(.semibold))
                }
            }
            if !cloud.accountState.isReady {
                Text("Sign in to iCloud and confirm the app's CloudKit setup, then tap Retry.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .listRowSeparator(.hidden)
    }

    /// Free-tier variant of the sync banner: cloud backup is Pro, so these events stay on the
    /// device. No Retry (it would no-op behind the `proActive` guard) — just the honest state.
    private var freeTierBanner: some View {
        HStack(spacing: 6) {
            Circle().fill(.secondary).frame(width: 8, height: 8)
            Text("iCloud backup is Pro — \(unsyncedCount) event(s) stay on this device")
                .font(.caption)
            Spacer()
        }
        .listRowSeparator(.hidden)
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
        if let data = event.thumbnailData, let ui = UIImage(data: data) {
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
                .overlay(Image(systemName: placeholderIcon).foregroundStyle(.secondary))
        }
    }

    /// Icon for an event with no captured image — a lock for a monitoring state change,
    /// otherwise the "no frame" camera glyph.
    private var placeholderIcon: String {
        switch event.stateChange {
        case "armed":    return "lock.fill"
        case "disarmed": return "lock.open.fill"
        case "gaLifted": return "lock.slash"
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
        Label(event.cloudSyncState.displayName, systemImage: "icloud")
            .foregroundStyle(color)
    }
}
