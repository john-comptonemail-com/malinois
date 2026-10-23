import XCTest
@testable import Malinois

/// Admission inspects only these test-owned files; no camera, account or simulator sensor is used.
final class PendingCameraEvidenceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func retainedFile(bytes: Int64, name: String = "retained.mov") throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data([41]).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
        return file
    }

    func testBothDestinationsReserveTheLastTwoSlotsTogether() throws {
        for index in 0..<1_198 { try Data().write(to: root.appendingPathComponent("\(index).mov")) }
        let destinations = try XCTUnwrap(CameraController.pendingMovieDestinations(in: root, outputs: 2))
        XCTAssertEqual(destinations.count, 2)
        XCTAssertEqual(Set(destinations.map(\.url)).count, 2)
        XCTAssertEqual(destinations.map(\.limit), [EventStore.maxMediaBytes / 2, EventStore.maxMediaBytes / 2])
        // Starting front consumes a file slot. Rear keeps its original reservation rather
        // than performing another two-slot admission check and failing half the capture.
        try Data([1]).write(to: destinations[0].url)
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root, outputs: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinations[1].url.path))
    }

    func testFileCountBudgetReservesRoomForEveryRequestedOutput() throws {
        for index in 0..<1_198 { try Data().write(to: root.appendingPathComponent("\(index).mov")) }
        XCTAssertNotNil(CameraController.pendingMovieAllowance(in: root, outputs: 2))
        try Data().write(to: root.appendingPathComponent("one-more.mov"))
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root, outputs: 2))
        XCTAssertNotNil(CameraController.pendingMovieAllowance(in: root))
        try Data().write(to: root.appendingPathComponent("last.mov"))
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1_200)
    }

    func testMultipleSparseFilesCannotExceedBudget() throws {
        _ = try retainedFile(bytes: 1_100_000_000, name: "front.mov")
        _ = try retainedFile(bytes: 1_100_000_000, name: "rear.mov")
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    /// A file larger than the room left refuses admission before its size is counted: sparse
    /// files can claim sizes whose running total overflows (a crash), where the final "room
    /// left" check would come too late. The two-file case above stays inside the arithmetic;
    /// 513 sparse files of 2^54 bytes (the largest this file system takes is under 2^55) sum past
    /// what a 64-bit count holds (test-suite audit, WB74).
    func testHugeSparseFilesAreRefusedBeforeTheirSizesAreCounted() throws {
        do {
            for index in 0..<513 { _ = try retainedFile(bytes: 1 << 54, name: "huge-\(index).mov") }
        } catch {
            throw XCTSkip("this file system will not hold sparse files that large: \(error)")
        }
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root))
    }

    func testHardLinkedEntriesRefuseAdmissionAndKeepTheirTarget() throws {
        let target = try retainedFile(bytes: 3)
        let link = root.appendingPathComponent("link.mov")
        try FileManager.default.linkItem(at: target, to: link)
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root))
        XCTAssertEqual(try Data(contentsOf: target), Data([41, 0, 0]))
    }

    func testUnknownDirectoryAndInvalidOutputCountsFailClosed() throws {
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root.appendingPathComponent("missing")))
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root, outputs: 0))
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root, outputs: 3))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("unexpected"), withIntermediateDirectories: false)
        XCTAssertNil(CameraController.pendingMovieAllowance(in: root))
    }
}
