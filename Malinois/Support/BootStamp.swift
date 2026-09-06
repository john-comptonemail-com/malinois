//
//  BootStamp.swift
//  Malinois
//
//  Tells a device restart apart from an app kill after the fact (BACKLOG 53). An armed
//  session that ends without a clean disarm used to be logged as a bare "interrupted"; a
//  stamp taken when the session arms and compared at the next launch says whether the
//  device rebooted in between — the one interruption nobody can block from inside an app.
//

import Foundation

/// The kernel's boot timestamp, paired with the wall clock at the moment it was read.
///
/// Two stamps — one stored when a session arms, one taken at the next launch — answer "did
/// the device restart in between?" without trusting either clock alone:
///
/// - `bootTime` is `kern.boottime`, the wall-clock moment the kernel booted. It is a stored
///   timestamp, not a running counter, so time the device spends asleep cannot skew it
///   (`ProcessInfo.systemUptime` pauses in deep sleep, which is why it is not used here). A
///   restart moves it forward by the previous session's uptime plus the time the device was
///   off — a minute or more for any arm that reached this code — while automatic clock
///   corrections move it by fractions of a second.
/// - `uptime` is what the kernel keeps consistent across clock changes: setting the clock
///   shifts `bootTime` by the same amount, so `takenAt - bootTime` is immune to a moved clock.
///   Uptime going *backwards* is therefore proof of a restart even when the clock was wound
///   back far enough to hide the boot-time jump.
struct BootStamp: Equatable, Sendable {
    /// `kern.boottime`, in seconds since 1970.
    let bootTime: TimeInterval
    /// The wall clock when the stamp was read, in seconds since 1970.
    let takenAt: TimeInterval

    /// Seconds the system had been up when the stamp was read, sleep included.
    var uptime: TimeInterval { takenAt - bootTime }

    /// Boot-time movement at or below this is clock drift, not a restart. A restart moves the
    /// boot time by the previous session's uptime plus the downtime — over a minute in
    /// practice — while automatic time corrections are sub-second. The one thing that can
    /// fool it is a manual clock change of more than this between arm and relaunch, which
    /// Guided Access rules out while armed.
    static let driftTolerance: TimeInterval = 30

    /// Reads the kernel's boot time now. `nil` only if the kernel refuses the query, which no
    /// supported iOS does; callers treat `nil` as "cannot classify", never as a restart.
    static func current(now: Date = Date()) -> BootStamp? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, UInt32(mib.count), &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        let bootTime = TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000
        return BootStamp(bootTime: bootTime, takenAt: now.timeIntervalSince1970)
    }

    /// Pure (unit-tested). Why a session that was armed at `armed` is no longer running when
    /// the app comes up at `current`: the device restarted, or the app alone was ended.
    ///
    /// `nil` when there is nothing to compare — a marker planted by a build that predates the
    /// stamp, or a kernel that would not answer — so the record stays an honest bare
    /// "interrupted" rather than a guess.
    static func classify(armed: BootStamp?, current: BootStamp?,
                         tolerance: TimeInterval = driftTolerance) -> InterruptionCause? {
        guard let armed, let current else { return nil }
        // A restart moves the boot time forward by far more than any clock correction.
        if current.bootTime - armed.bootTime > tolerance { return .rebooted }
        // Uptime cannot shrink without a restart, whatever was done to the clock.
        if armed.uptime - current.uptime > tolerance { return .rebooted }
        return .terminated
    }
}
