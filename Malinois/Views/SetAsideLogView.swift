//
//  SetAsideLogView.swift
//  Malinois
//
//  A set-aside event log's screen and its row in the Event Log (BACKLOG item 122; the owner, 2026-11-07: "as you
//  recommend, wording approved"). The screen reads the file when it opens and never writes it: the records it could read,
//  each opening read only, a mark on a record the event log also has, and no iCloud badge on it (item 214), Share of the
//  whole file with the photos and clips it names, and Delete, which removes it and at once the photos and clips only it
//  names. The Event Log opens with the PIN or, where the owner turned that on, a face or finger, and so does this screen;
//  Delete asks for the PIN itself, every time, and then for a confirmation (item 232: a face or finger opens what is read,
//  and deletes nothing).
//

import SwiftUI

/// A set-aside log's row in the Event Log: when it was set aside and how many records it could and could not read.
struct SetAsideLogRow: View {
    let log: SetAsideLog
    @State private var reading: SetAsideLog.Reading?

    var body: some View {
        Label {
            Text(reading.map { SetAsideLogWords.row(setAsideAt: log.setAsideAt, records: $0.records.count, unreadable: $0.unreadable) }
                 ?? SetAsideLogWords.title)
                .font(.subheadline)
        } icon: {
            Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
        }
        .task(id: log.id) { reading = await Task.detached { [log] in SetAsideLog.read(log) }.value }
    }
}

/// A set-aside log's own screen (item 122's decision 1 (a)): the records it could read, read only; nothing goes back into
/// the log, so what the phone signed about them stays true.
struct SetAsideLogView: View {
    let log: SetAsideLog
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var engine: MonitoringEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var reading: SetAsideLog.Reading?
    /// Delete's steps: its PIN pad, then its confirmation (item 232).
    @State private var deleteSteps = SetAsideLogDeleteSteps()
    /// While Delete runs: the screen leaves for the Event Log once it is done.
    @State private var deleting = false
    /// The sheet Share opened, with the ZIP it sends.
    @State private var sharing: ShareRequest?
    /// The ZIP the open sheet sends, removed once the sheet is gone.
    @State private var sharedZIP: URL?
    /// While Share makes the ZIP, before its sheet opens.
    @State private var preparing = false

    var body: some View {
        List {
            Section {
                Text(SetAsideLogWords.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let reading {
                if reading.records.isEmpty {
                    Text(SetAsideLogWords.noneReadable)
                        .foregroundStyle(.secondary)
                } else {
                    let inTheLog = Set(eventStore.events.map(\.id))
                    ForEach(reading.records) { record in
                        let alsoInLog = inTheLog.contains(record.id)
                        NavigationLink {
                            EventDetailView(event: record, setAside: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                EventRow(event: record, setAside: true, alsoInLog: alsoInLog)
                                if alsoInLog {
                                    Text(SetAsideLogWords.alsoInLog)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .reportedOnScreen(SetAsideLogWords.alsoInLog)
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
            Section {
                Button(SetAsideLogWords.deleteButton, role: .destructive) { deleteSteps.deletePressed() }
                    .disabled(deleting)
                    .reportedAction(SetAsideLogWords.deleteButton) { deleteSteps.deletePressed() }
            }
        }
        .listStyle(.plain)
        .confirmationDialog(SetAsideLogWords.deleteTitle, isPresented: $deleteSteps.confirming, titleVisibility: .visible) {
            Button(SetAsideLogWords.deleteButton, role: .destructive, action: delete)
        } message: {
            Text(SetAsideLogWords.deleteMessage)
        }
        .reportedDialog(SetAsideLogWords.deleteTitle, isPresented: $deleteSteps.confirming,
                        button: SetAsideLogWords.deleteButton + ": " + SetAsideLogWords.deleteTitle, delete)
        // The PIN only, whatever opened the Event Log: this pad is never given leave to take a face or finger. The
        // confirmation opens once the pad has gone, as Home opens a screen after its own pad.
        .fullScreenCover(isPresented: $deleteSteps.askingPIN, onDismiss: padHasGone) {
            PINEntryView(title: SetAsideLogWords.deletePINTitle) {
                deleteSteps.pinWasEntered()
            } onCancel: {
                deleteSteps.padWasCancelled()
            }
        }
        // Only the background: Control Centre or a call's banner over Malinois closes nothing, as on Home.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            deleteSteps.malinoisLeftTheScreen()
        }
        .navigationTitle(SetAsideLogWords.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if preparing {
                    ProgressView()
                } else {
                    Button(action: startShare) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
            }
        }
        .task(id: log.id) { reading = await Task.detached { [log] in SetAsideLog.read(log) }.value }
        .sheet(item: $sharing, onDismiss: finishShare) { ShareSheet(items: $0.items) }
    }

    /// Makes the ZIP off the main thread (a log's clips can be large), then opens the sheet with it alone.
    private func startShare() {
        guard sharing == nil, !preparing else { return }
        preparing = true
        let mediaDirectory = eventStore.mediaDirectory
        Task {
            let zip = await Task.detached { [log] in try? SetAsideLogShare.zip(of: log, mediaDirectory: mediaDirectory) }.value
            preparing = false
            guard let zip else { return }
            sharedZIP = zip
            sharing = ShareRequest(items: [zip])
        }
    }

    /// iOS says the PIN pad has gone: Delete's steps say whether the confirmation opens.
    private func padHasGone() {
        deleteSteps.padHasGone()
    }

    /// Deletes the log, and at once the photos and clips only it names (item 122's decision 3 (a)), then leaves for the Event
    /// Log, which lists what is left, and says so when Delete may have left the log's photos and clips or deleted nothing:
    /// the store keeps that answer for it (item 227's DS-5). The Delete is the engine's, which writes its status entry
    /// (item 234): no screen deletes through the store.
    private func delete() {
        guard !deleting else { return }
        deleting = true
        Task {
            _ = await engine.deleteSetAsideLog(log)   // the delete and its status entry, one step (item 234)
            deleting = false
            dismiss()
        }
    }

    /// Once the sheet is gone: its ZIP removed, off the main thread.
    private func finishShare() {
        guard let zip = sharedZIP else { return }
        sharedZIP = nil
        Task.detached { SetAsideLogShare.remove(zip) }
    }
}
