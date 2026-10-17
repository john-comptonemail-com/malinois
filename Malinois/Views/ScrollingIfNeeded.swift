//
//  ScrollingIfNeeded.swift
//  Malinois
//
//  A screen laid out as designed, or scrolling when it is taller than the room it is given
//  (items 108 and 82).
//

import SwiftUI

extension View {
    /// This view as laid out, or scrolling when it is taller than the room it is given. A stack fits
    /// a short screen by squeezing its text, which cuts lines off with "…": the countdown's battery
    /// note on an iPhone SE once a warning joined it (item 108), and Home's notices and the PIN
    /// setup's explanation on the iPhone Duo's outer display (item 82). Large text does the same on
    /// any iPhone. A screen it fits looks exactly as before; scrolling, the scroll bar flashes once
    /// so it is plain that there is more below. SwiftUI keeps the view twice, one copy for each
    /// layout, so keep sheets, alerts and `onChange` outside it.
    func scrollingIfNeeded() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView { self }
                .scrollIndicatorsFlash(onAppear: true)
        }
    }
}
