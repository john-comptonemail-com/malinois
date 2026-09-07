//
//  CommonModeTimer.swift
//  Malinois
//
//  One way to make a timer for the engine's security and safety transitions (item 73, review
//  2 R2.3): `Timer.scheduledTimer` runs in the run loop's `.default` mode only, which pauses
//  while the loop is tracking a touch — a scroll drag, a pressed control — so a dismiss, a
//  debounce, a sweep or a watchdog scheduled that way could miss its moment. The grace and
//  calibration countdowns learned this first ("stalls at N for ~10s"); every timer that
//  participates in a transition goes through here now.
//

import Foundation

extension Timer {
    /// A timer that keeps firing while the run loop is tracking a touch — scheduled on the main
    /// run loop in the `.common` modes. Same shape as `Timer.scheduledTimer(withTimeInterval:
    /// repeats:block:)`, so a call site changes one name.
    @discardableResult
    static func commonMode(interval: TimeInterval, repeats: Bool,
                           block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
