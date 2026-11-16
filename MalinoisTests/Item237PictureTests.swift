//
//  Item237PictureTests.swift
//  MalinoisTests
//
//  BACKLOG item 237's first half (1.13, item 240's list; the owner, 2026-11-12: "as you recommend";
//  docs/design/1.13-fixes.md, part 4a): an event's screen decodes a photo off the main thread and put it up when the
//  decode returned, without asking whether the screen still wanted it. After another device's update moved a file to
//  the other camera's place, the old decode could put the picture back under the wrong camera until the screen was
//  left. Now only the latest load puts its picture up. Through the real view, laid out in a window, with real JPEGs and
//  a decode the test holds and lets go. Written before the fix, red at that commit (where the view loads through
//  `EvidencePictureLoad` as before, with no check).
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item237PictureTests: XCTestCase {
    nonisolated(unsafe) private var folder = URL(fileURLWithPath: NSTemporaryDirectory())
    nonisolated(unsafe) private var heldDecodes: HeldDecodes?

    // Synchronous, as TestIsolation asks: XCTest calls them on the main thread, outside the main actor's isolation.
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem237")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item237-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        heldDecodes = MainActor.assumeIsolated { () -> HeldDecodes in
            let decodes = HeldDecodes()
            EvidencePictureLoad.decodeForTesting = decodes.decode
            return decodes
        }
    }

    override func tearDown() {
        let decodes = heldDecodes
        MainActor.assumeIsolated {
            // A held decode is let go, so that no test's run waits on it after it ends.
            decodes?.letAllGo()
            EvidencePictureLoad.decodeForTesting = nil
        }
        heldDecodes = nil
        try? FileManager.default.removeItem(at: folder)
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// The decodes of this test.
    private var decodes: HeldDecodes {
        get throws { try XCTUnwrap(heldDecodes, "set up by setUp") }
    }

    /// A guard, green before the fix and after: the view puts up the photo of its file.
    func testTheViewPutsUpThePhotoOfItsFile() async throws {
        let first = try photo("first", width: 40, height: 30, colour: .red)
        let place = Place(first)
        let screen = try Screen(PlaceView(place: place))
        defer { screen.close() }
        try await screen.wait(for: "the first photo") { screen.pictures == ["first.jpg"] }
    }

    /// Another device's update gave the first place another file while the old one was still being decoded: the old
    /// decode, returning late, does not put its picture back.
    func testAPhotoDecodedAfterTheViewMovedOnIsNotPutUp() async throws {
        let first = try photo("first", width: 40, height: 30, colour: .red)
        let second = try photo("second", width: 30, height: 40, colour: .blue)
        let decodes = try self.decodes
        decodes.hold("first.jpg")
        let place = Place(first)
        let screen = try Screen(PlaceView(place: place))
        defer { screen.close() }
        try await screen.wait(for: "the first photo's decode, held") { decodes.isHeld("first.jpg") }
        place.url = second
        try await screen.wait(for: "the second photo") { screen.pictures == ["second.jpg"] }
        decodes.letGo("first.jpg")
        try await screen.settle()
        XCTAssertEqual(screen.pictures, ["second.jpg"], "the first photo's decode, returning late, is not put up")
    }

    /// The first place has no file now (another device's update moved it): the old decode, returning late, puts up no
    /// picture there.
    func testAPhotoIsNotPutUpWhereItsFileNoLongerIs() async throws {
        let first = try photo("first", width: 40, height: 30, colour: .red)
        let decodes = try self.decodes
        decodes.hold("first.jpg")
        let place = Place(first)
        let screen = try Screen(PlaceView(place: place))
        defer { screen.close() }
        try await screen.wait(for: "the first photo's decode, held") { decodes.isHeld("first.jpg") }
        place.url = nil
        try await screen.settle()
        decodes.letGo("first.jpg")
        try await screen.settle()
        XCTAssertEqual(screen.pictures, [], "no photo where no file is")
    }

    /// A guard, green before the fix and after: a clip gets its player, and no photo.
    func testAClipGetsItsPlayer() async throws {
        let clip = folder.appendingPathComponent("clip.mov")
        try Data([0, 1, 2, 3]).write(to: clip)
        let picture = EvidencePictureLoad()
        await picture.load(clip)
        XCTAssertNotNil(picture.player)
        XCTAssertNil(picture.image)
        XCTAssertEqual(try decodes.asked, [], "a clip is not decoded as a photo")
    }

    // MARK: - Helpers

    /// A real JPEG of one colour, `width` by `height`, saved as `<name>.jpg` in the test's folder.
    private func photo(_ name: String, width: Int, height: Int, colour: UIColor) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let url = folder.appendingPathComponent(name + ".jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }
}

/// The place on an event's screen whose file a test changes, as another device's update would.
@MainActor
private final class Place: ObservableObject {
    @Published var url: URL?

    init(_ url: URL?) { self.url = url }
}

private struct PlaceView: View {
    @ObservedObject var place: Place

    var body: some View { EvidenceMediaView(url: place.url, fallbackThumbnail: nil) }
}

/// The view's decodes, each a real one, which a test can hold until it lets it go.
@MainActor
private final class HeldDecodes {
    /// The files' names, in the order their decodes were asked for.
    private(set) var asked: [String] = []
    private var toHold: Set<String> = []
    private var held: [String: CheckedContinuation<Void, Never>] = [:]

    func hold(_ name: String) { toHold.insert(name) }

    func isHeld(_ name: String) -> Bool { held[name] != nil }

    func letGo(_ name: String) {
        toHold.remove(name)
        held.removeValue(forKey: name)?.resume()
    }

    func letAllGo() {
        toHold.removeAll()
        let all = held.values
        held.removeAll()
        all.forEach { $0.resume() }
    }

    func decode(_ url: URL) async -> UIImage? {
        let name = url.lastPathComponent
        asked.append(name)
        if toHold.contains(name) {
            await withCheckedContinuation { held[name] = $0 }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return BoundedImageDecoder.image(from: data, maxPixelSize: BoundedImageDecoder.fullDisplayPixels)
    }
}

/// A view laid out in a window for the length of a test, with what it reports on screen.
@MainActor
private final class Screen {
    let recorder = OnScreenRecorder()
    private let window: UIWindow
    private let controller: UIHostingController<AnyView>

    init(_ view: some View) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host's window scene")
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller = UIHostingController(rootView: AnyView(view.environment(\.onScreenRecorder, recorder)))
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
    }

    /// The photos on screen, by their files' names.
    var pictures: [String] {
        recorder.shown.filter { $0.hasPrefix(EvidenceMediaView.pictureReport) }
            .map { String($0.dropFirst(EvidenceMediaView.pictureReport.count)) }
    }

    /// Lets SwiftUI run until `condition` holds; after three seconds, fails, naming what it waited for.
    func wait(for what: String, until condition: () -> Bool,
              file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        controller.view.layoutIfNeeded()
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutIfNeeded()
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what); on screen: \(recorder.shown)", file: file, line: line)
    }

    /// Lets SwiftUI run for a while, for what must not happen.
    func settle() async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .milliseconds(400))
        while clock.now < end {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutIfNeeded()
        }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
