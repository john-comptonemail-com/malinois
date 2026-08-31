//
//  DryRunView.swift
//  Malinois
//
//  Live "Test Sensors" mode: arms the enabled tripwires and shows their readings
//  in real time WITHOUT recording anything or going covert. Lets the user confirm
//  placement, tune sensitivity, and see it work before a real arm — without
//  polluting the (undeletable) event log.
//

import SwiftUI

struct DryRunView: View {
    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var entitlements: ProEntitlements
    @EnvironmentObject private var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    private var testedSensors: [SensorType] {
        SensorType.tripwires.filter { settings.isEnabled($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // ~10 Hz re-render so the "would trip" highlights decay smoothly.
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    VStack(spacing: 14) {
                        Text("Move, tap, or make noise near the phone to see each sensor react. Nothing is recorded and no events are logged.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        if let n = engine.dryRunCountdown {
                            // Settle window (BACKLOG 12): the hand that tapped the button must
                            // be off the phone before the noise floor is learned.
                            HStack(spacing: 8) {
                                Image(systemName: "hand.raised")
                                Text("Set the phone down — calibrating in \(n)…")
                            }
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                        } else if engine.dryRunActive && engine.lastCalibration == nil {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Calibrating…").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }

                        if let cal = engine.lastCalibration, !cal.isEmpty {
                            CalibrationSummaryView(summary: cal)
                        }

                        ForEach(testedSensors) { sensor in
                            if sensor == .touch {
                                touchPad
                            } else if SensorType.proTripwires.contains(sensor) && !entitlements.proActive {
                                // The audio tripwire is Pro; on the free tier the monitor is
                                // clamped off, so show why it won't react instead of a dead
                                // reading (P-03).
                                proLockedRow(sensor)
                            } else {
                                SensorReadingRow(
                                    sensor: sensor,
                                    reading: engine.dryRunReadings[sensor],
                                    count: engine.dryRunCounts[sensor] ?? 0,
                                    tripped: isTripped(sensor, reading: engine.dryRunReadings[sensor]))
                            }
                        }

                        if testedSensors.isEmpty {
                            ContentUnavailableView("No sensors enabled",
                                                   systemImage: "sensor.tag.radiowaves.forward",
                                                   description: Text("Enable sensors in Settings to test them."))
                                .padding(.top, 40)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Test Sensors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Disabled during the settle countdown — it is already recalibrating.
                    Button("Recalibrate") { engine.recalibrateDryRun() }
                        .disabled(engine.dryRunCountdown != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // 2.5.14: the test warms the camera for the vision row, so the indicator shows here too.
        .overlay(alignment: .top) {
            if camera.isRecordingActive { RecordingIndicator().transition(.opacity) }
        }
        .onAppear { engine.startDryRun() }
        .onDisappear { engine.stopDryRun() }
    }

    private func isTripped(_ sensor: SensorType, reading: SensorReading?) -> Bool {
        if reading?.hot == true { return true }
        // Linger longer than the flash so a proximity cover-then-uncover (during
        // which the screen was off) is still visibly highlighted on return.
        if let last = engine.dryRunTrips[sensor], Date().timeIntervalSince(last) < 1.8 { return true }
        return false
    }

    /// Free-tier stand-in for the audio row: the sensor is enabled in the user's settings but
    /// clamped off without Pro, so it can never react in the test (P-03).
    private func proLockedRow(_ sensor: SensorType) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(sensor.displayName, systemImage: sensor.iconName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("PRO")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Brand.blue.opacity(0.15)))
                    .foregroundStyle(Brand.blue)
            }
            Text("The \(sensor.displayName.lowercased()) tripwire is a Pro feature. It stays off on the free tier, so it won't react here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private var touchPad: some View {
        let tripped = isTripped(.touch, reading: nil)
        let count = engine.dryRunCounts[.touch] ?? 0
        return VStack(spacing: 6) {
            Image(systemName: "hand.tap.fill").font(.title2)
            Text(tripped ? "TOUCH DETECTED" : "Tap here to test touch")
                .font(.subheadline.weight(tripped ? .bold : .regular))
            if count > 0 {
                Text("detected \(count)×").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(tripped ? Color.red : .secondary)
        .frame(maxWidth: .infinity, minHeight: 90)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(tripped ? Color.red.opacity(0.15) : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onTapGesture { engine.dryRunReportTouch() }
        .animation(.easeOut(duration: 0.2), value: tripped)
    }
}

/// One sensor's live value, bar, and trip threshold — highlighted red when it's
/// currently over the trip point (or just fired in the test).
struct SensorReadingRow: View {
    let sensor: SensorType
    let reading: SensorReading?
    let count: Int
    let tripped: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(sensor.displayName, systemImage: sensor.iconName)
                    .font(.subheadline.weight(.semibold))
                if count > 0 {
                    Text("\(count)×")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(reading?.value ?? "—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(tripped ? Color.red : .primary)
            }
            ProgressView(value: reading?.level ?? 0)
                .tint(tripped ? .red : Brand.blue)
            Text(tripped ? "WOULD TRIP" : (reading?.detail ?? "…"))
                .font(.caption2.weight(tripped ? .bold : .regular))
                .foregroundStyle(tripped ? Color.red : .secondary)
            Text(sensor.testHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(tripped ? Color.red : Color.clear, lineWidth: 2))
        .animation(.easeOut(duration: 0.2), value: tripped)
    }
}

/// The calibration result card — reused by the arming review and the test view.
struct CalibrationSummaryView: View {
    let summary: CalibrationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let q = summary.motionQuality {
                row("Resting stability", q, summary.motionDetail)
            }
            if let q = summary.audioQuality {
                row("Ambient noise", q, summary.audioDetail)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.blue.opacity(0.10)))
    }

    private func row(_ label: String, _ quality: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(quality).font(.subheadline.weight(.semibold))
            }
            Spacer()
            if let detail {
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
