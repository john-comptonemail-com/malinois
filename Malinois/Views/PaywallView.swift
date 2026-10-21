//
//  PaywallView.swift
//  Malinois
//
//  The single upgrade sheet. Presented from the Home banner, the Settings Pro row, and any
//  Pro-locked control. Sells the one-time unlock — leading with "one time, no subscription,"
//  the wedge against subscription competitors. Reuses the app's brand styling.
//
//  During Early-Access (BACKLOG 66) it is a support screen instead: Pro is already the
//  owner's, free and permanently, and the purchase is labelled as what it then is — support
//  for the project that adds nothing. The same product, the same button, honest copy.
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
                        Text(entitlements.status == .earlyAccess ? "Early-Access: Free, permanently"
                                                                  : "One time. No subscription.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.benefits, id: \.title) { b in
                            benefitRow(b, emphasized: b.feature == highlight)
                        }
                    }
                    .padding(.horizontal, 8)

                    if entitlements.status == .earlyAccess {
                        Text("Pro is free for Early-Access installs, permanently. If Pro ever becomes a paid unlock, that will apply to new installs only.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Text("Buying adds nothing you don't already have. It supports the project, and that is all it does.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else if entitlements.status == .trial {
                        Text("You're in your free trial\(entitlements.trialDaysRemaining.map { " — \($0) day\($0 == 1 ? "" : "s") left" } ?? ""). Buy now to keep Pro when it ends.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Text("Your data stays yours. No account, no server, nothing sent to the developer.")
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
                    Text(working ? "…"
                         : Self.priced(entitlements.status == .earlyAccess ? "Support Malinois" : "Unlock Pro",
                                       displayPrice: entitlements.product?.displayPrice))
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || entitlements.status == .pro)   // buyable during the trial and Early-Access, not after purchase
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
        .background(.bar)
    }

    /// `label` with the App Store's price appended, or `label` alone until StoreKit has supplied
    /// one (item 108, D-07). The price is the storefront's own, in its currency; a fixed "$9.99"
    /// used to stand in, shown in every country and before the product had loaded.
    static func priced(_ label: String, displayPrice: String?) -> String {
        guard let displayPrice else { return label }
        return "\(label) - \(displayPrice)"
    }

    /// "One-time" and the App Store's price, as a sentence; without a price yet, "One-time purchase."
    static func oneTimeCaption(displayPrice: String?) -> String {
        displayPrice.map { "One-time \($0)." } ?? "One-time purchase."
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
              title: "Evidence backed up to iCloud",
              detail: "Uploading starts as soon as a tamper fires, the record before the photo, so evidence can outlast a power-off."),
        .init(feature: .crossDevicePush, icon: "iphone.radiowaves.left.and.right",
              title: "Alerts on your other devices",
              detail: "Your other iPhone, iPad and Apple Watch get a tamper alert when they can be reached."),
        .init(feature: .multiCam, icon: "camera.on.rectangle",
              title: "Both cameras at once",
              detail: "Capture the face and the room together."),
        .init(feature: .extendedVideo, icon: "video",
              title: "5-second & until-clear clips",
              detail: "More frames to catch a face, not just a single still."),
        .init(feature: .audioSensor, icon: "waveform",
              title: "Sound tripwire",
              detail: "Trips on a sudden sound nearby."),
        .init(feature: .visionSensor, icon: "eye",
              title: "Vision tripwire",
              detail: "While the camera is ready (on a charger by default), it watches its view for movement, catching someone approaching before they touch it.")
    ]
}
