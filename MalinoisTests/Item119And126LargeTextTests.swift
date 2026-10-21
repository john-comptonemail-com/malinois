//
//  Item119And126LargeTextTests.swift
//  MalinoisTests
//
//  BACKLOG 119 and 126 (1.8, BACKLOG 128 step 2): at the largest accessibility text size on a short
//  screen, Home's Event Log and Settings buttons broke their names into fragments ("E / v / …"),
//  because the two sit side by side below the part of Home that scrolls; and the PIN screens (the
//  disarm pad, the Event Log, Settings and Test Sensors gates, the PIN change) cut off their title
//  and lockout message, because they did not scroll. Written before the fixes, red at that commit.
//  A text that is cut off is laid out shorter than its words need at its width: each test measures
//  the text's laid-out frame (the screens report it, Debug only, `OnScreenText.swift`) against the
//  height UIKit gives the same words in the same font at that width. The short screens are the
//  smallest the app supports (an iPhone SE below its status bar) and the room the iPhone Duo's outer
//  display gives an app; the guards check that standard text on a 17 Pro lays out as before. The
//  look at the other screens at the largest size in the same pass (BACKLOG 128) added the tamper
//  warning, the calibration card and the "PIN was kept" screen, and moved Home's stacked buttons
//  into the part that scrolls.
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item119And126LargeTextTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "Item119And126LargeTextTests")
        KeychainService.wipeStalePINData()
    }

    override func tearDown() {
        KeychainService.wipeStalePINData()
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static let shortScreens = [CGSize(width: 375, height: 647),   // iPhone SE, below the status bar
                                       CGSize(width: 387, height: 645)]   // the iPhone Duo's outer display
    private static let iPhone17Pro = CGSize(width: 402, height: 874)
    private static let largest = DynamicTypeSize.accessibility5

    // MARK: - Item 119: Home's bottom buttons

    /// At the largest text size the two buttons stack, each the full width, and each shows its whole
    /// name: "Event Log (2 new)", the longest it gets in practice, and "Settings". They sit at the end
    /// of the part of Home that scrolls: pinned below it, stacked, they left it a window a few lines
    /// tall, with ARM out of sight (seen on this item's look at the screens at the largest size).
    func testHomesButtonsStackAndShowTheirWholeNamesAtTheLargestTextSize() throws {
        let rig = makeRig()
        rig.store.markAllSeen()
        rig.store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .pending))
        rig.store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .pending))
        let log = "Event Log (2 new)"
        for size in Self.shortScreens {
            let screen = try layout(of: home(rig).environment(\.dynamicTypeSize, Self.largest), in: size)
            let logLabel = try XCTUnwrap(screen.frames[log], "no \"\(log)\" button at \(size)")
            let settingsLabel = try XCTUnwrap(screen.frames["Settings"], "no Settings button at \(size)")
            XCTAssertGreaterThanOrEqual(settingsLabel.minY, logLabel.maxY - 0.5,
                                        "the buttons sit side by side at \(size), each with half the width")
            assertWholeText(log, laidOutIn: logLabel, style: .body, size: Self.largest, at: size)
            assertWholeText("Settings", laidOutIn: settingsLabel, style: .body, size: Self.largest, at: size)
            let middle = try XCTUnwrap(screen.scrollers.max { $0.frame.height < $1.frame.height },
                                       "Home does not scroll at \(size)")
            XCTAssertGreaterThan(middle.frame.height, size.height / 2,
                                 "the part of Home that scrolls is left \(middle.frame.height) of \(size.height) at \(size)")
            XCTAssertLessThanOrEqual(settingsLabel.maxY, middle.frame.minY + middle.contentHeight + 0.5,
                                     "the buttons are not in the part that scrolls, below ARM, at \(size)")
        }
    }

    /// Guard: at the standard text size the buttons stay side by side, names whole.
    func testHomesButtonsStaySideBySideAtTheStandardTextSize() throws {
        let rig = makeRig()
        let screen = try layout(of: home(rig), in: Self.iPhone17Pro)
        let logLabel = try XCTUnwrap(screen.frames["Event Log"])
        let settingsLabel = try XCTUnwrap(screen.frames["Settings"])
        XCTAssertEqual(logLabel.midY, settingsLabel.midY, accuracy: 1, "no longer side by side")
        XCTAssertLessThan(logLabel.maxX, settingsLabel.minX, "no longer side by side")
        assertWholeText("Event Log", laidOutIn: logLabel, style: .body, size: .large, at: Self.iPhone17Pro)
        assertWholeText("Settings", laidOutIn: settingsLabel, style: .body, size: .large, at: Self.iPhone17Pro)
    }

    // MARK: - Item 126: the PIN screens

    /// A gate's PIN screen (here Settings', locked out after five wrong PINs, so at its tallest) shows
    /// its whole title and lockout message at the largest text size, and scrolls to reach the rest.
    func testAPINGateShowsItsWholeTitleAndLockoutAtTheLargestTextSize() throws {
        try lockOut()
        let title = "Enter PIN for Settings"
        for size in Self.shortScreens {
            let pad = PINEntryView(title: title, onSuccess: {}, onCancel: {})
                .environmentObject(AppSettings())
                .environment(\.dynamicTypeSize, Self.largest)
            let screen = try layout(of: pad, in: size)
            try assertWholePIN(title: title, on: screen, at: size)
        }
    }

    /// The disarm pad, at the largest text size and locked out, with the camera running: the whole
    /// title and lockout message, and the armed time and the REC badge on screen in rows of their own,
    /// clear of the title (they were laid over the top of the pad).
    func testTheDisarmPadShowsItsWholeTitleBelowTheArmedTimeAndRECBadge() throws {
        try lockOut()
        let rig = makeRig()
        try armAndOpenThePad(rig)
        rig.camera.setRecordingActive(true)
        for size in Self.shortScreens {
            let screen = try layout(of: armed(rig).environment(\.dynamicTypeSize, Self.largest), in: size)
            let title = try assertWholePIN(title: Self.disarmTitle, on: screen, at: size)
            let window = CGRect(origin: .zero, size: size)
            for badge in [Self.armedFor, Self.recBadge] {
                let frame = try XCTUnwrap(screen.frames[badge], "no \(badge) on the disarm pad at \(size)")
                XCTAssertTrue(window.contains(frame), "\(badge) is off screen at \(size): \(frame)")
                XCTAssertGreaterThanOrEqual(title.minY, frame.maxY - 0.5,
                                            "\(badge) lies over the disarm pad's title at \(size): \(frame) over \(title)")
            }
        }
        rig.engine.disarm()
    }

    /// Guard: at the standard text size on a 17 Pro the disarm pad fits without scrolling, its title
    /// whole and clear of the armed time and of the REC badge. (Before the fix this host shows the
    /// screen's REC badge only for a real camera, so the guard checks it where it is shown.)
    func testTheDisarmPadFitsATallPhoneAtTheStandardTextSize() throws {
        let rig = makeRig()
        try armAndOpenThePad(rig)
        rig.camera.setRecordingActive(true)
        let screen = try layout(of: armed(rig), in: Self.iPhone17Pro)
        let title = try XCTUnwrap(screen.frames[Self.disarmTitle], "no disarm pad title")
        assertWholeText(Self.disarmTitle, laidOutIn: title, style: .title2, weight: .semibold, size: .large,
                        at: Self.iPhone17Pro)
        for scroller in screen.scrollers {
            XCTAssertLessThanOrEqual(scroller.contentHeight, scroller.frame.height + 0.5,
                                     "the disarm pad scrolls on a 17 Pro at the standard size")
        }
        let armedFor = try XCTUnwrap(screen.frames[Self.armedFor], "no armed time on the disarm pad")
        XCTAssertGreaterThanOrEqual(title.minY, armedFor.maxY - 0.5, "the armed time lies over the title")
        if let rec = screen.frames[Self.recBadge] {
            XCTAssertGreaterThanOrEqual(title.minY, rec.maxY - 0.5, "the REC badge lies over the title")
        }
        rig.engine.disarm()
    }

    // MARK: - Seen on this item's look at the other screens at the largest size

    /// The tamper warning cut its message and the disarm tip short ("This devic…", "To disarm:…"). It
    /// cannot scroll: touches must reach the armed screen beneath it (Touch, the hold that opens the
    /// pad). Its text now stops growing two steps above the standard size, where it fits a short screen.
    func testTheTamperWarningShowsItsWholeMessageAndTipAtTheLargestTextSize() throws {
        let message = AppSettings.defaultAlertMessage
        let tip = try XCTUnwrap(DisarmTip.alertTip(hasDisarmedOnce: false))
        for size in Self.shortScreens {
            let warning = AlertMessageView(message: message, disarmTip: tip)
                .environment(\.dynamicTypeSize, Self.largest)
            let screen = try layout(of: warning, in: size)
            let shown = try XCTUnwrap(screen.frames[message], "no message at \(size)")
            assertWholeText(message, laidOutIn: shown, style: .title3, weight: .bold, size: AlertMessageView.largestTextSize, at: size)
            let tipFrame = try XCTUnwrap(screen.frames[tip], "no tip at \(size)")
            assertWholeText(tip, laidOutIn: tipFrame, style: .callout, weight: .semibold, size: AlertMessageView.largestTextSize, at: size)
            let footnote = try XCTUnwrap(screen.frames[DisarmTip.alertTipFootnote], "no footnote at \(size)")
            assertWholeText(DisarmTip.alertTipFootnote, laidOutIn: footnote, style: .caption1, size: AlertMessageView.largestTextSize, at: size)
            for frame in [shown, tipFrame, footnote] {
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame), "off screen at \(size): \(frame)")
            }
        }
    }

    /// The calibration card (the "Calibrated" card and Test Sensors) set its label and its reading side
    /// by side, so at the largest size each column was a few letters wide and words broke ("Rest- / ing
    /// / stabili- / ty"). Each now has the card's width there.
    func testTheCalibrationCardKeepsItsWordsWholeAtTheLargestTextSize() throws {
        let summary = CalibrationSummary(motionQuality: "Unsteady - may false-trip", motionDetail: "Background motion: 0.020 g",
                                         audioQuality: nil, audioDetail: nil)
        for size in Self.shortScreens {
            let card = CalibrationSummaryView(summary: summary).padding().environment(\.dynamicTypeSize, Self.largest)
            let screen = try layout(of: ScrollView { card }, in: size)
            for (text, style, weight) in [("Resting stability", UIFont.TextStyle.caption1, UIFont.Weight.regular),
                                          ("Unsteady - may false-trip", .subheadline, .semibold),
                                          ("Background motion: 0.020 g", .caption1, .regular)] {
                let frame = try XCTUnwrap(screen.frames[text], "no \"\(text)\" at \(size)")
                assertWordsWhole(text, laidOutIn: frame, style: style, weight: weight, size: Self.largest, at: size)
            }
        }
    }

    /// After a reinstall that kept the PIN, "Your Malinois PIN was kept" cut its title, its explanation
    /// and "Use existing PIN" short. It now scrolls when taller than the screen.
    func testThePINKeptScreenShowsItsWholeTextAtTheLargestTextSize() throws {
        let title = "Your Malinois PIN was kept"
        let explanation = "Enter your existing PIN to resume. If you forgot it, verify with Face ID, Touch ID, or your device passcode to choose a new one."
        let button = "Use existing PIN"
        for size in Self.shortScreens {
            let screen = try layout(of: PINContinuityView(kind: .lostSetupFlag) {}.environment(\.dynamicTypeSize, Self.largest),
                                    in: size)
            for (text, style, weight) in [(title, UIFont.TextStyle.title2, UIFont.Weight.semibold),
                                          (explanation, .body, .regular), (button, .body, .regular)] {
                let frame = try XCTUnwrap(screen.frames[text], "no \"\(text)\" at \(size)")
                assertWholeText(text, laidOutIn: frame, style: style, weight: weight, size: Self.largest, at: size)
            }
        }
    }

    // MARK: - Checks

    private static let disarmTitle = "Enter PIN to disarm"
    private static let armedFor = "Armed for"
    private static let recBadge = "REC"
    private static let lockoutPrefix = "Too many attempts"

    /// The title and the lockout message laid out whole, and the pad in a scroll view, so the rest
    /// (Cancel below the keypad) is reachable where it is taller than the screen. Returns the title's frame.
    @discardableResult
    private func assertWholePIN(title: String, on screen: Layout, at size: CGSize,
                                file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let titleFrame = try XCTUnwrap(screen.frames[title], "no title at \(size)", file: file, line: line)
        assertWholeText(title, laidOutIn: titleFrame, style: .title2, weight: .semibold, size: Self.largest,
                        at: size, file: file, line: line)
        let lockout = try XCTUnwrap(screen.frames.first { $0.key.hasPrefix(Self.lockoutPrefix) },
                                    "no lockout message at \(size)", file: file, line: line)
        assertWholeText(lockout.key, laidOutIn: lockout.value, style: .footnote, size: Self.largest,
                        at: size, file: file, line: line)
        // Where the pad is taller than the room it scrolls (laid out whole, as checked above); where it
        // fits it does not need to. Either way the pad's scroll view stays within the screen.
        let scroller = try XCTUnwrap(screen.scrollers.first,
                                     "the PIN screen does not scroll at \(size), so what does not fit is cut off",
                                     file: file, line: line)
        XCTAssertLessThanOrEqual(scroller.frame.maxY, size.height + 0.5, "the pad runs off the screen at \(size)",
                                 file: file, line: line)
        return titleFrame
    }

    /// `text` laid out in `frame` shows all its words: the frame is as tall as UIKit lays out the
    /// same words in the same font at the frame's width. A text cut off with "…", or squeezed to a
    /// few letters a line, is laid out shorter than that.
    private func assertWholeText(_ text: String, laidOutIn frame: CGRect, style: UIFont.TextStyle,
                                 weight: UIFont.Weight = .regular, size: DynamicTypeSize, at screen: CGSize,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let category = UIContentSizeCategory(size)
        let base = UIFont.preferredFont(forTextStyle: style,
                                        compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
        let needed = (text as NSString).boundingRect(with: CGSize(width: frame.width, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: [.font: font], context: nil).height
        // UIKit and SwiftUI space lines a little differently: allow 4 points, or 2% of a long text.
        XCTAssertGreaterThanOrEqual(frame.height, needed.rounded(.up) - max(4, needed * 0.02),
                                    "\"\(text)\" is cut off at \(screen): laid out \(frame.height) tall in \(frame.width), needs \(needed)",
                                    file: file, line: line)
    }

    /// No word of `text` is broken across lines in `frame`: the frame is at least as wide as the
    /// widest word in the same font, and the text is laid out whole.
    private func assertWordsWhole(_ text: String, laidOutIn frame: CGRect, style: UIFont.TextStyle,
                                  weight: UIFont.Weight = .regular, size: DynamicTypeSize, at screen: CGSize,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let category = UIContentSizeCategory(size)
        let base = UIFont.preferredFont(forTextStyle: style,
                                        compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
        let widest = text.split(separator: " ").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        XCTAssertGreaterThanOrEqual(frame.width, widest.rounded(.down) - 1,
                                    "\"\(text)\" breaks its words at \(screen): \(frame.width) wide, its widest word needs \(widest)",
                                    file: file, line: line)
        assertWholeText(text, laidOutIn: frame, style: style, weight: weight, size: size, at: screen, file: file, line: line)
    }

    // MARK: - Rig

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
        let settings: AppSettings
        let cloud: CloudExfiltrator
        let entitlements: ProEntitlements
    }

    /// The test engine's timings, but the disarm pad stays up until a test closes it: the shortened
    /// half-second timeout would close it between two screen sizes.
    private static let timing: EngineTiming = {
        var timing = EngineCharacterizationTests.fastTiming
        timing.disarmEntryTimeout = 60
        timing.disarmEntryCeiling = 120
        return timing
    }()

    private func makeRig() -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let camera = FakeCamera()
        let store = EventStore()
        let cloud = CloudExfiltrator()
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: camera, entitlements: entitlements,
                                                          timing: Self.timing))
        return Rig(engine: engine, camera: camera, store: store, settings: settings, cloud: cloud,
                   entitlements: entitlements)
    }

    /// Five wrong PINs after a real one: the pad then shows the lockout message, at its tallest.
    private func lockOut() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable in this build — skipped")
        for _ in 0..<5 { XCTAssertFalse(KeychainService.verify("0000")) }
        XCTAssertGreaterThan(KeychainService.lockoutRemaining(), 0, "locked out")
    }

    private func armAndOpenThePad(_ rig: Rig) throws {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed && rig.engine.armedSince != nil }, timeout: 5), "armed")
        rig.engine.beginDisarmEntry()
        XCTAssertTrue(rig.engine.disarmEntryActive, "the disarm pad is open")
    }

    private func home(_ rig: Rig) -> some View {
        HomeView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(rig.cloud)
            .environmentObject(rig.store)
            .environmentObject(rig.entitlements)
    }

    private func armed(_ rig: Rig) -> some View {
        ArmedView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(CameraController())
    }

    // MARK: - Laying out a real screen

    /// A scroll view on screen: its laid-out content height and its frame in the window.
    private struct Scroller {
        let contentHeight: CGFloat
        let frame: CGRect
    }

    private struct Layout {
        let frames: [String: CGRect]
        let scrollers: [Scroller]
    }

    /// `view` laid out in a window of `size` (item 82's pattern: at the origin, safe areas ignored, so
    /// `size` is exactly the room the screen gets): where its reporting texts are, and its scroll views,
    /// read before the window closes.
    private func layout<V: View>(of view: V, in size: CGSize) throws -> Layout {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let recorder = OnScreenRecorder()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutIfNeeded()
        var scrollers: [Scroller] = []
        var pending: [UIView] = [window]
        while let next = pending.popLast() {
            pending.append(contentsOf: next.subviews)
            guard let scroll = next as? UIScrollView, !scroll.isHidden, scroll.alpha > 0, scroll.bounds.height > 0
            else { continue }
            scrollers.append(Scroller(contentHeight: scroll.contentSize.height,
                                      frame: scroll.convert(scroll.bounds, to: window)))
        }
        return Layout(frames: recorder.frames, scrollers: scrollers)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
