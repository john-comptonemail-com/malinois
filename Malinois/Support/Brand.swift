//
//  Brand.swift
//  Malinois
//
//  The Malinois visual identity. This file carries the palette pulled from the
//  original artwork; the shipped marks are `MalinoisEmblem` (the arm control),
//  `MalinoisWordmark` (the home lockup), and `Collar` (Pro / trial status). The
//  cobalt is also the asset-catalog AccentColor, so system controls (buttons,
//  pickers, toggles) match for free.
//

import SwiftUI
import UIKit

enum Brand {
    /// Cobalt signal blue — the same value as the AccentColor asset.
    static let blue = Color.accentColor
    /// The logo's charcoal field.
    static let charcoal = Color(red: 0.086, green: 0.098, blue: 0.114)
    /// The dark ground the emblem artwork sits on — used as the ARM button's fill so
    /// the emblem's own background blends seamlessly into the control.
    static let emblemGround = Color(red: 34/255, green: 37/255, blue: 42/255)
    /// A deeper cobalt for type set ON the emblem ground (the ARM label). The AccentColor
    /// cobalt is tuned for small system controls on a light background and reads brighter
    /// than the logo's blue when placed on the dark emblem field; this matches the artwork.
    static let blueDeep = Color(red: 0.129, green: 0.396, blue: 0.760)
}

/// The spiked-collar mark used for Pro/trial status — Malinois's stand-in for the generic
/// "crown" premium glyph. Full-colour artwork (black strap, chrome spikes) with a lightened
/// dark-mode variant in the asset catalog, so it's rendered `.original`, not tinted. A custom
/// asset — unlike an SF Symbol — does NOT scale itself to the surrounding font, and this one is
/// wide (≈1.6:1), so callers give the HEIGHT to match their text and the width follows.
struct CollarIcon: View {
    /// Roughly the cap height of the text it sits beside (caption2 ≈ 12, body ≈ 16).
    var height: CGFloat = 12

    var body: some View {
        Image("Collar")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityHidden(true)      // the adjacent label already says "Pro"
    }
}

/// The MALINOIS wordmark (silver "MALINOIS" + tagline on its dark banner), shown as
/// the Home hero. The wide artwork fills most of the screen horizontally; the width
/// scales with the device (a fraction of the screen's shorter side, so a Pro Max
/// shows it bigger than a mini) as a *ceiling* — `scaledToFit` lets it compress if
/// the layout is tight, so it never overflows. The banner keeps its own dark ground
/// so the silver lettering reads on any app theme.
struct MalinoisLockup: View {
    /// Fraction of the screen's shorter side the wordmark may grow to.
    var widthFraction: CGFloat = 0.92

    private var maxWidth: CGFloat {
        let screen = UIScreen.main.bounds.size
        return min(screen.width, screen.height) * widthFraction
    }

    var body: some View {
        Image("MalinoisWordmark")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: maxWidth)
            .accessibilityLabel("Malinois — Device Anti-Tampering")
    }
}
