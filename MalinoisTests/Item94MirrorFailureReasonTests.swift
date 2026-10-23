//
//  Item94MirrorFailureReasonTests.swift
//  MalinoisTests
//
//  BACKLOG 94 (the ultracode review's U4, item 93; ruled for after 1.4). A capture that fails
//  attaches no evidence, so the full push after it keeps the fact's revision, and a mirror that
//  already held the fact refused the fuller copy: the store took an equal revision only when a
//  count grew. The other phone never learned why there was no photo. At equal revisions, a copy
//  that newly carries a failure reason now replaces one without it; the reason only ever
//  appears, so a copy that has lost it is still refused, and the counts still may not go down.
//

import XCTest
@testable import Malinois

final class Item94MirrorFailureReasonTests: XCTestCase {

    private let id = UUID()
    private let start = Date(timeIntervalSince1970: 1_000)
    private let reason = CaptureFailureReason.cameraUnavailable.rawValue

    /// Another phone's copy of one event, at the fact's revision unless told otherwise.
    private func mirror(failure: String?, floods: Int? = nil, rev: Int = 1) -> Event {
        Event(id: id, startDate: start, endDate: start.addingTimeInterval(2), triggeredSensors: [.motion],
              sustainedCount: floods, sourceDevice: "iPhone Air", cloudRevision: rev, captureFailure: failure)
    }

    // MARK: - The rule

    /// The fact first, then the full push at the same revision with the reason: the reason is taken.
    func testAFailureReasonReachesAMirrorThatHeldOnlyTheFact() {
        XCTAssertTrue(EventStore.supersedes(incoming: mirror(failure: reason), existing: mirror(failure: nil)))
    }

    /// A copy without the reason never replaces one that has it: a replay of the fact, arriving late.
    /// Even when its flood count grew: with equal counts the copy is refused for changing nothing,
    /// so only a grown count leaves the reason rule to decide (test-suite audit, WB41).
    func testACopyThatLostTheReasonIsRefused() {
        XCTAssertFalse(EventStore.supersedes(incoming: mirror(failure: nil), existing: mirror(failure: reason)))
        XCTAssertFalse(EventStore.supersedes(incoming: mirror(failure: nil, floods: 5),
                                             existing: mirror(failure: reason, floods: 3)),
                       "a higher count does not buy losing the reason")
    }

    /// The same copy again changes nothing.
    func testAnIdenticalCopyChangesNothing() {
        XCTAssertFalse(EventStore.supersedes(incoming: mirror(failure: reason), existing: mirror(failure: reason)))
    }

    /// A reason does not buy a count going down: a copy with the reason and fewer flood trips is refused.
    func testTheCountsStillMayNotGoDown() {
        XCTAssertFalse(EventStore.supersedes(incoming: mirror(failure: reason, floods: 1),
                                             existing: mirror(failure: nil, floods: 3)))
    }

    /// First-hand evidence is never replaced, whatever a cloud copy carries.
    func testFirstHandEvidenceIsNeverReplaced() {
        var firstHand = mirror(failure: nil)
        firstHand.sourceDevice = nil
        XCTAssertFalse(EventStore.supersedes(incoming: mirror(failure: reason), existing: firstHand))
    }

    // MARK: - Through the merge

    /// The other phone's log: after the fuller copy is fetched, its row says why there is no photo.
    func testTheOtherPhoneShowsWhyThereIsNoPhoto() {
        let merged = EventStore.merged(local: [mirror(failure: nil)], incoming: [mirror(failure: reason)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertNotNil(merged.first?.captureFailureSummary, "the row explains the missing photo")
    }
}
