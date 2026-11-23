// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

final class ProtectedDataProbeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        let probe = directory.appendingPathComponent("nested/probe")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: probe.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("nested").path)
        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstLaunchWritesTheProbeAndCountsAsAvailable() {
        let probe = ProtectedDataProbe(url: directory.appendingPathComponent("nested/probe"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.url.path))
        XCTAssertTrue(probe.isAvailable())
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.url.path), "the next launch reads it")
        XCTAssertTrue(probe.isAvailable())
    }

    /// A locked class key refuses the read. A file the process may not read stands in for it.
    func testARefusedReadIsLocked() throws {
        let probe = ProtectedDataProbe(url: directory.appendingPathComponent("nested/probe"))
        XCTAssertTrue(probe.isAvailable())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: probe.url.path)
        XCTAssertFalse(probe.isAvailable(), "Zone must wait instead of starting on empty preferences")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: probe.url.path)
        XCTAssertTrue(probe.isAvailable(), "the first unlock makes it readable again")
    }

    /// Before the first unlock a new file of the class cannot be created either.
    func testARefusedFirstWriteIsLocked() throws {
        let folder = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertFalse(ProtectedDataProbe(url: folder.appendingPathComponent("probe")).isAvailable())
    }

    func testOnlyPermissionErrorsCountAsLocked() {
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        XCTAssertTrue(ProtectedDataProbe.isProtectionRefusal(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                                                                      userInfo: [NSUnderlyingErrorKey: eperm])))
        XCTAssertTrue(ProtectedDataProbe.isProtectionRefusal(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                                      userInfo: [NSUnderlyingErrorKey: eperm])))
        XCTAssertTrue(ProtectedDataProbe.isProtectionRefusal(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertFalse(ProtectedDataProbe.isProtectionRefusal(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
                       "a full disk must not keep Zone from starting")
        XCTAssertFalse(ProtectedDataProbe.isProtectionRefusal(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
    }
}
