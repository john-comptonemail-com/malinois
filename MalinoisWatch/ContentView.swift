//
//  ContentView.swift
//  MalinoisWatch
//
//  The watch's one screen (item 57, ADR 0042): whether alerts will arrive here. Alerts appear as
//  notifications; their details stay on the iPhone.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var state: WatchAlertState

    var body: some View {
        let status = WatchAlertStatus.describe(WatchAlertStatus.Checks(
            registration: state.registration, account: state.account, notifications: state.notifications,
            subscriptions: state.subscriptions, link: state.link, lastAlert: state.lastAlert,
            lastAlertSource: state.lastAlertSource))
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Malinois")
                    .font(.headline)
                Text(status.headline)
                    .font(.title3.weight(.semibold))
                Text(status.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(status.lines, id: \.self) { line in
                    Text(line)
                        .font(.caption2)
                }
                Text("Alerts follow Cross-device alerts in Malinois on your iPhone. Details stay on the iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
