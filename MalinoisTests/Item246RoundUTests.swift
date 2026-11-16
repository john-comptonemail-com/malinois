//
//  Item246RoundUTests.swift
//  MalinoisTests
//
//  BACKLOG item 246, round u: a crash at PIN setup on an App Store user's iPhone (1.12 (87), an iPhone 16 on iOS 26.6,
//  2026-11-14). While an animation ran, SwiftUI's background render thread built the PIN pad's rows of keys, and
//  Swift 6's main-thread check at the start of the row builder stopped the app (Apple's FB20692404). A closure written
//  in a view is main-actor code, and SwiftUI stores the builders of loops, geometry readers and timelines and may call
//  them on that thread. These tests call the pad's loop builders off the main thread, as that thread does; hold the
//  app's code to the rule that no builder SwiftUI stores and calls while it renders is written as main-actor code; and
//  go through the flow the crash interrupted, from a first PIN to its confirmation, on a short screen at a large text
//  size, with each key of each pad there to press.
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

/// A loop's builder, called for each of its items on the calling thread, as SwiftUI's render thread calls it while it
/// builds a loop's rows (item 246).
private protocol LoopRowBuilder {
    func buildEveryRow() -> [Any]
}

extension ForEach: LoopRowBuilder {
    fileprivate func buildEveryRow() -> [Any] { data.map { content($0) } }
}

/// A value handed to another thread by a test that touches it nowhere else meanwhile.
private final class Handed<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
final class Item246RoundUTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    /// The app's targets, whose code the rule covers.
    private static let appFolders = ["Malinois", "MalinoisWatch", "MalinoisNotificationService",
                                     "MalinoisWatchNotificationService"]
    /// The SwiftUI views that store a builder and may call it while they render (item 246).
    nonisolated private static let storedBuilders = ["ForEach", "GeometryReader", "TimelineView", "Canvas"]
    private static let shortScreen = CGSize(width: 375, height: 667)

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem246")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The pad's builders, off the main thread

    /// The crash: the pad's loop builders, called off the main thread as SwiftUI's render thread called the row builder
    /// while an animation ran. Every pad the app shows: the setup's, with a slot for each digit, at both lengths, and
    /// the entry's, concealed and scrambled, with ✓ and without. Before the fix, the first builder called stops the
    /// test process, as it stopped the app.
    func testThePINPadsLoopBuildersRunOffTheMainThread() {
        let pads = [Handed<Any>(PINPad(digits: .constant("12"), maxLength: 4).body),
                    Handed<Any>(PINPad(digits: .constant("12"), maxLength: 6).body),
                    Handed<Any>(PINPad(digits: .constant("123"), maxLength: 6, conceal: true, scramble: true).body),
                    Handed<Any>(PINPad(digits: .constant("123"), maxLength: 6, conceal: true, scramble: true,
                                       autoSubmitLength: 4).body)]
        for (number, pad) in pads.enumerated() {
            let built = Self.offTheMainThread { Self.buildLoopRows(in: pad.value) }
            XCTAssertNotNil(built, "pad \(number): its builders did not finish off the main thread")
        }
    }

    /// The walk the test above relies on reaches a loop inside a body and builds its rows: a loop whose builder may
    /// run anywhere, two rows.
    func testTheWalkReachesALoopsRowsInsideABody() {
        let body = Handed<Any>(VStack { ForEach(["a", "b"], id: \.self) { @Sendable in Text($0) } }.padding())
        XCTAssertEqual(Self.offTheMainThread { Self.buildLoopRows(in: body.value) }, 2)
    }

    // MARK: - The rule, over the app's code

    /// No builder SwiftUI stores and calls while it renders is main-actor code (item 246): in the app's code, the
    /// builder of each `ForEach`, `GeometryReader`, `TimelineView` or `Canvas` is marked `@Sendable`, which makes it
    /// belong to no actor and lets Swift prove it uses nothing of the main thread's, or the view is one of the app's
    /// own, which build their content on the main thread. Reads the sources, so it fails on Xcode Cloud, where they are
    /// not on the test machine.
    func testNoBuilderSwiftUIStoresAndCallsWhileRenderingIsMainActorCode() throws {
        var found: [String] = []
        for folder in Self.appFolders {
            let base = Self.root.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                XCTFail("no folder \(folder)")
                continue
            }
            for case let file as URL in files where file.pathExtension == "swift" {
                let code = Self.codeOnly(try String(contentsOf: file, encoding: .utf8))
                let path = file.path.replacingOccurrences(of: Self.root.path + "/", with: "")
                for site in Self.storedBuilderSites(in: code) where !site.sendable {
                    found.append("\(path):\(site.line) \(site.name)")
                }
            }
        }
        XCTAssertEqual(found.sorted(), [], "builders SwiftUI may call off the main thread, written as main-actor code")
    }

    /// The rule's reading finds what it should and only that: a loop, a geometry reader and a timeline whose builders
    /// are main-actor code; not one marked `@Sendable`, not the app's own views, not a comment or a string.
    func testTheRulesReadingFindsABuilderWrittenAsMainActorCodeAndNothingElse() {
        let code = Self.codeOnly(#"""
            ForEach(items, id: \.self) { item in row(item) }
            ForEach(items) { @Sendable in Text($0) }
            MainActorForEach(items) { item in row(item) }
            GeometryReader { room in content(room) }
            // ForEach(items) { item in row(item) }
            let words = "ForEach(items) { item in row(item) }"
            TimelineView(.periodic(from: .now,
                                   by: 1)) { context in Text(context.date, style: .time) }
            GeometryReader { @Sendable proxy in content(proxy.size) }
            """#)
        let sites = Self.storedBuilderSites(in: code)
        XCTAssertEqual(sites.map(\.line), [1, 2, 4, 7, 9])
        XCTAssertEqual(sites.filter { !$0.sendable }.map(\.name), ["ForEach", "GeometryReader", "TimelineView"])
    }

    // MARK: - The flow the crash interrupted

    /// A first PIN through to its confirmation, as each of the user's five tries began before the crash: four digits,
    /// the move to "Confirm your PIN" with its animation, the same four digits, the PIN saved. On a short screen at a
    /// large text size, where the setup screen scrolls, as the crash's stack shows it did there.
    func testAFirstPINGoesThroughToItsConfirmationOnAShortScreenAtALargeTextSize() async throws {
        let saved = SavedPIN(), done = TestFlag()
        let screen = try layOut(PINSetupView(savePIN: { saved.pin = $0; return true }, onDone: { done.value = true })
                                    .dynamicTypeSize(.accessibility2),
                                size: Self.shortScreen)
        defer { screen.close() }
        await enter("7394", on: screen)
        try await Task.sleep(for: .seconds(1))   // the move to "Confirm your PIN", and its animation
        await enter("7394", on: screen)
        let finished = await settles { done.value }
        XCTAssertTrue(finished, "the PIN was not taken through its confirmation")
        XCTAssertEqual(saved.pin, "7394")
    }

    /// Every key of every pad is there to press: the ten digits and ⌫, with ✓ where the entry pad waits for it.
    func testEachPadShowsEveryKey() async throws {
        let digits = (0...9).map { "PIN key \($0)" }
        let pads: [(PINPad, [String])] = [
            (PINPad(digits: .constant(""), maxLength: 4), digits + ["PIN key ⌫"]),
            (PINPad(digits: .constant(""), maxLength: 6, conceal: true, scramble: true), digits + ["PIN key ⌫", "PIN key ✓"]),
            (PINPad(digits: .constant(""), maxLength: 6, conceal: true, autoSubmitLength: 4), digits + ["PIN key ⌫"])]
        for (pad, keys) in pads {
            let screen = try layOut(pad, size: Self.shortScreen)
            defer { screen.close() }
            let up = await settles { keys.allSatisfy { screen.recorder.actions[$0] != nil } }
            XCTAssertTrue(up, "keys: \(screen.recorder.actions.keys.sorted())")
            XCTAssertNil(screen.recorder.actions["PIN key "], "an empty place is not a key")
            if !keys.contains("PIN key ✓") { XCTAssertNil(screen.recorder.actions["PIN key ✓"]) }
        }
    }

    /// Six places for dots are enough: no pad takes more digits than that (the setup's lengths, the entry pad's 6).
    func testNoPadTakesMoreDigitsThanItHasPlacesForDots() {
        XCTAssertEqual(PINPad.maxDots, 6)
        XCTAssertLessThanOrEqual(PINSetupView.allowedLengths.max() ?? .max, PINPad.maxDots)
    }

    // MARK: - The app's own builders

    /// A loop of the app's own makes its rows wherever SwiftUI asks, and builds their content on the main thread: its
    /// builder, called off the main thread, makes the rows, by a list's order and by items' own identity; laid out, the
    /// rows show.
    func testTheAppsLoopMakesItsRowsAnywhereAndBuildsThemOnTheMainThread() async throws {
        let byOrder = MainActorForEach(["a", "b"], id: \.self) { Text($0).reportedOnScreen($0) }
        let byIdentity = MainActorForEach([SensorType.motion, .power, .proximity]) { Text($0.rawValue) }
        let bodies = [Handed<Any>(byOrder.body), Handed<Any>(byIdentity.body)]
        XCTAssertEqual(bodies.map { body in Self.offTheMainThread { Self.buildLoopRows(in: body.value) } }, [2, 3])
        let screen = try layOut(VStack { byOrder }, size: Self.shortScreen)
        defer { screen.close() }
        let shown = await settles { screen.recorder.shown.contains("a") && screen.recorder.shown.contains("b") }
        XCTAssertTrue(shown, "rows: \(screen.recorder.shown)")
    }

    /// A geometry reader of the app's own builds its content on the main thread from the size it is given: laid out in
    /// a window of a known width, its content shows that width.
    func testTheAppsGeometryReaderGivesItsContentTheSize() async throws {
        let screen = try layOut(MainActorGeometryReader { size in
            Text("width \(Int(size.width))").reportedOnScreen("width \(Int(size.width))")
        }, size: Self.shortScreen)
        defer { screen.close() }
        let shown = await settles { screen.recorder.shown.contains("width 375") }
        XCTAssertTrue(shown, "shown: \(screen.recorder.shown)")
    }

    /// A timeline of the app's own builds each page on the main thread from its date: laid out, its page shows.
    func testTheAppsTimelineShowsItsPage() async throws {
        let screen = try layOut(MainActorTimelineView(.periodic(from: .now, by: 1)) { date in
            Text("page").reportedOnScreen(date > .distantPast ? "page" : "no date")
        }, size: Self.shortScreen)
        defer { screen.close() }
        let shown = await settles { screen.recorder.shown.contains("page") }
        XCTAssertTrue(shown, "shown: \(screen.recorder.shown)")
    }

    // MARK: - Helpers

    /// The PIN the setup saved.
    private final class SavedPIN { var pin: String? }

    /// Types `pin` on the laid-out pad, key by key, as a finger would.
    private func enter(_ pin: String, on screen: Screen) async {
        for digit in pin.map(String.init) {
            let label = "PIN key " + digit
            let up = await settles { screen.recorder.actions[label] != nil }
            XCTAssertTrue(up, "no key \(digit) on the pad")
            screen.recorder.actions[label]?()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Runs `work` on a thread of its own, not the main one, and waits up to ten seconds for it, as SwiftUI's render
    /// thread runs a builder; nil when it has not finished.
    nonisolated private static func offTheMainThread(_ work: @escaping @Sendable () -> Int) -> Int? {
        let done = DispatchSemaphore(value: 0)
        let result = Handed<Int?>(nil)
        let thread = Thread {
            result.value = work()
            done.signal()
        }
        thread.start()
        return done.wait(timeout: .now() + 10) == .success ? result.value : nil
    }

    /// Calls the builder of every loop in `value` for every item, and of every loop in what those build, on the
    /// calling thread; the rows it built. Structures, enumerations, tuples and optionals are walked, objects are not: a
    /// binding's or a state's storage is an object, and none of a view's own code lives in one.
    nonisolated private static func buildLoopRows(in value: Any, depth: Int = 0) -> Int {
        guard depth < 80 else { return 0 }
        var built = 0
        if let loop = value as? LoopRowBuilder {
            for row in loop.buildEveryRow() { built += 1 + buildLoopRows(in: row, depth: depth + 1) }
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return built }
        for child in mirror.children { built += buildLoopRows(in: child.value, depth: depth + 1) }
        return built
    }

    /// A Swift source with its comments and string literals blanked out and its line breaks kept, so that a search
    /// finds code only, on the right lines.
    nonisolated private static func codeOnly(_ source: String) -> String {
        let chars = Array(source.utf16)
        var out = chars
        let space = UInt16(UInt8(ascii: " ")), newline = UInt16(UInt8(ascii: "\n"))
        let slash = UInt16(UInt8(ascii: "/")), star = UInt16(UInt8(ascii: "*"))
        let quote = UInt16(UInt8(ascii: "\"")), backslash = UInt16(UInt8(ascii: "\\"))
        func blank(_ from: Int, _ to: Int) {
            for index in from..<min(to, chars.count) where chars[index] != newline { out[index] = space }
        }
        func at(_ index: Int) -> UInt16? { index < chars.count ? chars[index] : nil }
        var index = 0
        while index < chars.count {
            if chars[index] == slash && at(index + 1) == slash {
                var end = index
                while end < chars.count && chars[end] != newline { end += 1 }
                blank(index, end)
                index = end
            } else if chars[index] == slash && at(index + 1) == star {
                var depth = 0, end = index
                repeat {
                    if at(end) == slash && at(end + 1) == star { depth += 1; end += 2 }
                    else if at(end) == star && at(end + 1) == slash { depth -= 1; end += 2 }
                    else { end += 1 }
                } while depth > 0 && end < chars.count
                blank(index, end)
                index = end
            } else if chars[index] == quote {
                let triple = at(index + 1) == quote && at(index + 2) == quote
                var end = index + (triple ? 3 : 1)
                while end < chars.count {
                    if chars[end] == backslash { end += 2; continue }
                    if triple && chars[end] == quote && at(end + 1) == quote && at(end + 2) == quote { end += 3; break }
                    if !triple && chars[end] == quote { end += 1; break }
                    if !triple && chars[end] == newline { break }
                    end += 1
                }
                blank(index, end)
                index = end
            } else {
                index += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Where `code` (comments and strings blanked) hands a builder to one of `storedBuilders`: the line, the view, and
    /// whether the builder is marked `@Sendable`. A builder passed in any other way than as the trailing closure counts
    /// as unmarked.
    nonisolated private static func storedBuilderSites(in code: String) -> [(line: Int, name: String, sendable: Bool)] {
        let text = code as NSString
        let pattern = "(?<![A-Za-z0-9_.])(" + storedBuilders.joined(separator: "|") + ")\\s*[({]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let chars = Array(code.utf16)
        let open = Set("([{".utf16), close = Set(")]}".utf16)
        let brace = UInt16(UInt8(ascii: "{")), newline = UInt16(UInt8(ascii: "\n"))
        func skipSpace(_ from: Int) -> Int {
            var index = from
            while index < chars.count, Character(UnicodeScalar(chars[index]) ?? " ").isWhitespace { index += 1 }
            return index
        }
        var sites: [(line: Int, name: String, sendable: Bool)] = []
        for match in regex.matches(in: code, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            var index = match.range.location + match.range.length - 1   // the "(" or "{"
            if chars[index] != brace {
                var depth = 0
                repeat {
                    if open.contains(chars[index]) { depth += 1 } else if close.contains(chars[index]) { depth -= 1 }
                    index += 1
                } while depth > 0 && index < chars.count
                index = skipSpace(index)
            }
            let line = chars[..<match.range.location].filter { $0 == newline }.count + 1
            guard index < chars.count, chars[index] == brace else {
                sites.append((line, name, false))
                continue
            }
            let start = skipSpace(index + 1)
            sites.append((line, name, text.substring(from: start).hasPrefix("@Sendable")))
        }
        return sites
    }

    /// Waits, releasing the main actor for SwiftUI, until `condition` holds or `seconds` pass.
    private func settles(within seconds: Int = 5, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// A screen laid out in a window that stays up until `close()`, with what it reports, so a test can press its
    /// buttons through their reported actions (item 122's pattern).
    private struct Screen {
        let recorder: OnScreenRecorder
        let host: UIViewController
        let window: UIWindow

        /// Whatever the screen still has up goes with it.
        @MainActor func close() {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func layOut<V: View>(_ view: V, size: CGSize) throws -> Screen {
        let recorder = OnScreenRecorder()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        return Screen(recorder: recorder, host: host, window: window)
    }
}
