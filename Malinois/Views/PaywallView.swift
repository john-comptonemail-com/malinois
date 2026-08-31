//
//  PaywallView.swift
//  Malinois
//
//  The single upgrade sheet. Presented from the Home banner, the Settings Pro row, and any
//  Pro-locked control. Sells the one-time unlock — leading with "one time, no subscription,"
//  the wedge against subscription competitors. Reuses the app's brand styling.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var entitlements: ProEntitlements
    @Environment(\.dismiss) private var dismiss

    /// Optional feature the user tapped, so we can lead with the most relevant line.
    var highlight: ProFeature?

    @State private var working = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image("MalinoisEmblem")
                        .resizable().scaledToFit()
                        .frame(height: 84)
                        .padding(.top, 12)

                    VStack(spacing: 6) {
                        Text("Malinois Pro")
                            .font(.largeTitle.weight(.bold))
                        Text("One time. No subscription.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.benefits, id: \.title) { b in
                            benefitRow(b, emphasized: b.feature == highlight)
                        }
                    }
                    .padding(.horizontal, 8)

                    if entitlements.status == .trial {
                        Text("You're in your free trial\(entitlements.trialDaysRemaining.map { " — \($0) day\($0 == 1 ? "" : "s") left" } ?? ""). Buy now to keep Pro when it ends.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Text("Your evidence stays yours — no account, no server, nothing sent to us.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if failed {
                        Text("Purchase didn't complete. Please try again.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { purchaseBar }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Restore") { Task { await entitlements.restore() } }
                        .font(.subheadline)
                }
            }
            .onChange(of: entitlements.status) { _, status in
                if status == .pro { dismiss() }   // purchased/restored → close (trial alone doesn't)
            }
        }
    }

    private var purchaseBar: some View {
        VStack(spacing: 6) {
            Button {
                Task {
                    working = true; failed = false
                    let ok = await entitlements.purchase()
                    working = false
                    if ok { dismiss() } else { failed = true }
                }
            } label: {
                HStack {
                    if working { ProgressView().tint(.white) }
                    Text(working ? "…" : "Unlock Pro — \(priceText)")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || entitlements.status == .pro)   // buyable during the trial, not after purchase
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var priceText: String {
        entitlements.product?.displayPrice ?? "$9.99"
    }

    private func benefitRow(_ b: Benefit, emphasized: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: b.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title).font(.subheadline.weight(.semibold))
                Text(b.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(emphasized ? 10 : 0)
        .background(emphasized ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
    }

    struct Benefit { let feature: ProFeature; let icon, title, detail: String }

    static let benefits: [Benefit] = [
        .init(feature: .cloudBackup, icon: "icloud.and.arrow.up",
              title: "Evidence survives a power-off",
              detail: "Pushed to your private iCloud the instant a tamper fires."),
        .init(feature: .crossDevicePush, icon: "iphone.radiowaves.left.and.right",
              title: "Instant alerts to your other devices",
              detail: "Know the moment your phone is touched, wherever you are."),
        .init(feature: .multiCam, icon: "camera.on.rectangle",
              title: "Both cameras at once",
              detail: "Capture the face and the room together."),
        .init(feature: .extendedVideo, icon: "video",
              title: "5-second & until-clear clips",
              detail: "More frames to catch a face — not just a single still."),
        .init(feature: .audioSensor, icon: "waveform",
              title: "Sound tripwire",
              detail: "Detect footsteps and handling noise nearby."),
        .init(feature: .visionSensor, icon: "eye",
              title: "Vision tripwire",
              detail: "While charging, the camera watches its view for movement — catching someone approaching before they touch it.")
    ]
}
