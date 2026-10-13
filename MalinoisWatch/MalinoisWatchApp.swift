//
//  MalinoisWatchApp.swift
//  MalinoisWatch
//
//  The Apple Watch app's entry point (item 57; ADR 0013 for the structure, ADR 0042 for the scope).
//  Alerts only: the watch receives the cross-device alert pushes and reads no iCloud records. It
//  never arms, disarms or writes anything.
//

import SwiftUI

@main
struct MalinoisWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(state: delegate.state)
        }
    }
}
