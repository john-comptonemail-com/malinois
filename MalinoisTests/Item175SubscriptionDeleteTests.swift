import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item175SubscriptionDeleteTests: XCTestCase {
    @MainActor private final class Calls {
        var asked: [String] = []
        var saved: [String] = []
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisSubscriptionDelete")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func makeCloud() async throws -> CloudExfiltrator {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let policy = CloudEnrollment(file: root.appendingPathComponent(UUID().uuidString + ".json"), authenticate: { _ in true })
        let enrolled = await policy.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let cloud = CloudExfiltrator(enrollment: policy)
        cloud.accountIdentityForTesting = { "account-a" }
        return cloud
    }

    /// The obsolete 1.0 ID is already absent; both current subscriptions really delete.
    func testTurningAlertsOffAcceptsAnAlreadyAbsentLegacySubscription() async throws {
        let cloud = try await makeCloud()
        let calls = Calls()
        cloud.subscriptionDeleteSubmitForTesting = { operation in
            calls.asked = operation.subscriptionIDsToDelete ?? []
            // CloudKit documents per-subscription callbacks as serial. Exercise its real Swift bridge that way.
            for id in calls.asked {
                let result: Result<Void, Error> = id == "malinois-tamper-meta-sub"
                    ? .failure(CKError(.unknownItem)) : .success(())
                operation.perSubscriptionDeleteBlock?(id, result)
            }
            let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey:
                ["malinois-tamper-meta-sub": CKError(.unknownItem)]])
            operation.modifySubscriptionsResultBlock?(.failure(partial))
        }
        let removed = await cloud.setCrossDeviceAlerts(false)
        XCTAssertTrue(removed)
        XCTAssertEqual(Set(calls.asked), Set(CloudExfiltrator.subscriptionIDsToRemove))
    }

    /// Neither an unanswered ID nor a real per-ID failure is hidden by operation success.
    func testAnUnconfirmedOrFailedSubscriptionKeepsAlertsOffUnconfirmed() async throws {
        for scenario in 0..<5 {
            let cloud = try await makeCloud()
            cloud.subscriptionDeleteSubmitForTesting = { operation in
                let ids = operation.subscriptionIDsToDelete ?? []
                for (index, id) in ids.enumerated() {
                    if scenario == 0 && index == 0 { continue }
                    let result: Result<Void, Error> = scenario == 1 && index == 0
                        ? .failure(CKError(.permissionFailure)) : .success(())
                    operation.perSubscriptionDeleteBlock?(id, result)
                }
                if scenario == 4, let first = ids.first {
                    // A contradictory callback is a defensive control, not a claimed normal server response.
                    operation.perSubscriptionDeleteBlock?(first, .failure(CKError(.permissionFailure)))
                }
                if scenario == 1, let first = ids.first {
                    let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey:
                        [first: CKError(.permissionFailure)]])
                    operation.modifySubscriptionsResultBlock?(.failure(partial))
                } else if scenario == 2 {
                    operation.modifySubscriptionsResultBlock?(.failure(CKError(.networkFailure)))
                } else { operation.modifySubscriptionsResultBlock?(.success(())) }
            }
            let removed = await cloud.setCrossDeviceAlerts(false)
            XCTAssertEqual(removed, scenario == 3, "scenario \(scenario): missing, per-ID error, operation error, all confirmed")
        }
    }

    func testAnAccountChangeBeforeDeletionCompletesStillFailsClosed() async throws {
        let cloud = try await makeCloud()
        cloud.subscriptionDeleteSubmitForTesting = { operation in
            for id in operation.subscriptionIDsToDelete ?? [] { operation.perSubscriptionDeleteBlock?(id, .success(())) }
            NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
            operation.modifySubscriptionsResultBlock?(.success(()))
        }
        let removed = await cloud.setCrossDeviceAlerts(false)
        XCTAssertFalse(removed)
    }

    /// The legacy subscription can disappear after the list but before its replacement setup deletes it.
    func testLegacyCleanupAcceptsAbsenceAndStillEstablishesBothCurrentSubscriptions() async throws {
        let cloud = try await makeCloud()
        let legacy = CKQuerySubscription(recordType: CloudExfiltrator.metaRecordType, predicate: NSPredicate(value: true),
            subscriptionID: "malinois-tamper-meta-sub", options: [.firesOnRecordCreation])
        cloud.existingSubscriptionsForTesting = { [legacy] }
        cloud.subscriptionDeleteSubmitForTesting = { operation in
            for id in operation.subscriptionIDsToDelete ?? [] {
                operation.perSubscriptionDeleteBlock?(id, .failure(CKError(.unknownItem)))
            }
            let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey:
                ["malinois-tamper-meta-sub": CKError(.unknownItem)]])
            operation.modifySubscriptionsResultBlock?(.failure(partial))
        }
        let calls = Calls()
        cloud.subscriptionSaveForTesting = { subscription in calls.saved.append(subscription.subscriptionID); return true }
        let enabled = await cloud.setCrossDeviceAlerts(true)
        XCTAssertTrue(enabled)
        XCTAssertEqual(Set(calls.saved), Set([CloudExfiltrator.makeTamperSubscription().subscriptionID,
                                      CloudExfiltrator.makeDisarmSubscription().subscriptionID]))
    }
    /// The reducer also handles older/alternative bridges that deliver an operation-level partial failure.
    func testTheReducerKeepsPartialFailureAndConflictingAnswersFailClosed() {
        let results = CloudExfiltrator.SubscriptionDeleteResults()
        results.record("a", .success(()))
        results.record("b", .failure(CKError(.unknownItem)))
        XCTAssertTrue(results.complete(operationError: CKError(.partialFailure), expecting: ["a", "b"]))
        XCTAssertFalse(results.complete(operationError: CKError(.partialFailure), expecting: ["a", "b", "missing"]))
        XCTAssertFalse(results.complete(operationError: CKError(.networkFailure), expecting: ["a", "b"]))
        results.record("b", .failure(CKError(.permissionFailure)))
        XCTAssertFalse(results.complete(operationError: nil, expecting: ["a", "b"]), "a later error overrides prior absence")

        // Stress our explicitly locked reducer directly, without concurrently invoking Apple's non-Sendable bridge.
        let concurrentResults = CloudExfiltrator.SubscriptionDeleteResults()
        let identifiers = (0..<128).map { "subscription-\($0)" }
        DispatchQueue.concurrentPerform(iterations: identifiers.count) { @Sendable index in
            let result: Result<Void, Error> = index.isMultiple(of: 2)
                ? .success(()) : .failure(CKError(.unknownItem))
            concurrentResults.record(identifiers[index], result)
            // Completion may overlap other writes; the final answer is asserted only after all work joins.
            _ = concurrentResults.complete(operationError: nil, expecting: identifiers)
        }
        XCTAssertTrue(concurrentResults.complete(operationError: CKError(.partialFailure), expecting: identifiers))
        XCTAssertFalse(concurrentResults.complete(operationError: nil, expecting: identifiers + ["missing"]))
        DispatchQueue.concurrentPerform(iterations: identifiers.count * 2) { @Sendable index in
            let result: Result<Void, Error> = index.isMultiple(of: 2)
                ? .success(()) : .failure(CKError(.permissionFailure))
            concurrentResults.record(identifiers[index / 2], result)
        }
        XCTAssertFalse(concurrentResults.complete(operationError: nil, expecting: identifiers),
                       "a real error remains sticky regardless of concurrent success ordering")
    }

}
