// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The App Group is worked out per build so Zone signed under any team still shares one container
/// between the app and the keyboard. Before, a build under another team hardcoded Zayd's group, and
/// the keyboard's requests never reached the app.
final class AppGroupTests: XCTestCase {
    private func reachable(_ groups: String...) -> (String) -> Bool {
        { groups.contains($0) }
    }

    func testDeclaredGroupWinsWhenReachable() {
        let group = AppGroup.resolve(declared: "group.com.friend.zone", provisioned: [],
                                     reachable: reachable("group.com.friend.zone", AppGroup.defaultIdentifier))
        XCTAssertEqual(group, "group.com.friend.zone")
    }

    func testZaydsBuildResolvesToTheOriginalGroup() {
        let group = AppGroup.resolve(declared: AppGroup.defaultIdentifier, provisioned: [AppGroup.defaultIdentifier],
                                     reachable: reachable(AppGroup.defaultIdentifier))
        XCTAssertEqual(group, "group.wtf.zayd.zone")
    }

    /// A sideloading tool re-signs with its own group and leaves the Info.plist alone.
    func testFallsBackToTheProfilesGroupWhenTheDeclaredOneIsUnreachable() {
        let group = AppGroup.resolve(declared: AppGroup.defaultIdentifier,
                                     provisioned: ["group.wtf.zayd.zone.ABCDE12345"],
                                     reachable: reachable("group.wtf.zayd.zone.ABCDE12345"))
        XCTAssertEqual(group, "group.wtf.zayd.zone.ABCDE12345")
    }

    /// The keyboard before Full Access reaches nothing; it keeps the declared group so it is right
    /// once access arrives.
    func testNothingReachableKeepsTheDeclaredGroup() {
        let group = AppGroup.resolve(declared: "group.com.friend.zone", provisioned: ["group.other"],
                                     reachable: { _ in false })
        XCTAssertEqual(group, "group.com.friend.zone")
    }

    func testIgnoresUnexpandedSettingsAndWildcards() {
        let group = AppGroup.resolve(declared: "$(ZONE_APP_GROUP)", provisioned: ["group.*", "*"],
                                     reachable: { _ in true })
        XCTAssertEqual(group, AppGroup.defaultIdentifier)
    }

    func testNoDeclarationUsesTheDefault() {
        XCTAssertEqual(AppGroup.resolve(declared: nil, provisioned: [], reachable: { _ in false }),
                       AppGroup.defaultIdentifier)
    }

    func testReadsGroupsFromAProvisioningProfile() throws {
        let plist: [String: Any] = [
            "Name": "iOS Team Provisioning Profile: com.friend.zone",
            "Entitlements": [
                "application-identifier": "ABCDE12345.com.friend.zone",
                "com.apple.security.application-groups": ["group.com.friend.zone"],
            ],
        ]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // A real profile wraps the plist in a binary CMS envelope; bytes on both sides stand in for it.
        var profile = Data([0x30, 0x82, 0x2A, 0x10, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7])
        profile.append(xml)
        profile.append(Data([0xA0, 0x82, 0x0D, 0x3C, 0x00, 0xFF]))
        XCTAssertEqual(AppGroup.provisionedGroups(fromProfile: profile), ["group.com.friend.zone"])
    }

    func testAProfileWithoutGroupsGivesNone() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": [String: Any]()], format: .xml, options: 0)
        XCTAssertEqual(AppGroup.provisionedGroups(fromProfile: xml), [])
        XCTAssertEqual(AppGroup.provisionedGroups(fromProfile: Data("not a profile".utf8)), [])
    }

    /// Reachability is a real write under Library/Caches, so a container whose root fails access()
    /// but whose Library is writable still counts, and a container nothing can write to does not.
    func testCanWriteCreatesAndRemovesAProbe() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        XCTAssertTrue(AppGroup.canWrite(in: container))
        let caches = container.appendingPathComponent("Library/Caches")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: caches.path), [])
    }

    func testCanWriteIsFalseWhenNothingIsWritable() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: container.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)
            try? FileManager.default.removeItem(at: container)
        }
        XCTAssertFalse(AppGroup.canWrite(in: container))
    }
}
