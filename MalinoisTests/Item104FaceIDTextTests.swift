//
//  Item104FaceIDTextTests.swift
//  MalinoisTests
//
//  BACKLOG 104 (1.6): iOS shows `NSFaceIDUsageDescription` when Malinois first uses Face ID.
//  Since 1.5.1, device authentication also confirms iCloud verification and turning cross-device
//  alerts off, and the text named neither. Written before the change, red at that commit.
//  BACKLOG 117 (1.7): turning iCloud backup off asks for device authentication too, and 1.6's What's
//  New promised the text lists every use. Red before the text named it.
//

import XCTest

final class Item104FaceIDTextTests: XCTestCase {

    /// The permission text names every use of device authentication, and still says settings and
    /// disarming need the Malinois PIN.
    func testTheFaceIDPermissionTextNamesEveryDeviceAuthenticationUse() throws {
        let text = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String)
        for use in ["evidence log", "sensor tests", "forgotten PIN", "iCloud access", "alerts", "iCloud backup"] {
            XCTAssertTrue(text.contains(use), "the Face ID permission text does not mention \(use): \(text)")
        }
        XCTAssertTrue(text.contains("Malinois PIN"), text)
    }
}
