//
//  FirstArmBriefingView.swift
//  Malinois
//
//  The one-time screen before the first arm (BACKLOG 131): how to disarm and, when Guided Access is on for the
//  arm, how to end it. Shown over the Guided Access step once Start countdown has asked for it; its one button
//  acknowledges what it showed and starts the countdown.
//

import Combine
import SwiftUI

/// The one-time screen before the first arm (item 131), in the owner's approved wording (`FirstArmBriefing`). Its
/// text scrolls at any text size, and its button stays in view below it. While a camera runs it shows the REC badge,
/// in a row of its own, as the arming screens do (guideline 2.5.14).
struct FirstArmBriefingView: View {
    /// The parts to show.
    let parts: FirstArmBriefing.Parts
    /// Whether a camera session runs: the engine's camera (`isRecordingActivePublisher`).
    let recording: AnyPublisher<Bool, Never>
    /// The button: acknowledges the parts shown and starts the countdown.
    let onAcknowledge: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(FirstArmBriefing.title)
                    .font(.title2.weight(.bold))
                    .reportedOnScreen(FirstArmBriefing.title)
                if parts.disarm {
                    section(FirstArmBriefing.disarmHeading, [FirstArmBriefing.disarmText])
                }
                if parts.guidedAccess {
                    section(FirstArmBriefing.guidedAccessHeading,
                            [FirstArmBriefing.guidedAccessText, FirstArmBriefing.forgotPasscodeText])
                }
                line(FirstArmBriefing.footnote, font: .footnote, color: .secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onAcknowledge) {
                Text(FirstArmBriefing.button)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)   // one line, not "I" over "understand", at the largest text sizes
                    .reportedOnScreen(FirstArmBriefing.button)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .recordingBadge(whileLive: recording)
        .interactiveDismissDisabled()
    }

    private func section(_ heading: String, _ texts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .reportedOnScreen(heading)
            ForEach(texts, id: \.self) { line($0, font: .body, color: .primary) }
        }
    }

    private func line(_ text: String, font: Font, color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)   // never cut short at a large text size
            .reportedOnScreen(text)
    }
}
