// by zayd/cold @ zayd.wtf

import Foundation

/// Which App Group the app and the keyboard share, worked out at launch instead of hardcoded.
///
/// An App Group identifier belongs to one Apple team. Anyone building Zone under their own team
/// (or re-signing it with a sideloading tool) gets a different group, and a hardcoded
/// `group.wtf.zayd.zone` then resolves to no container in either process: each side reads and writes
/// its own private copy, the keyboard's requests never reach the app ("Zone could not find the
/// dictation request from the keyboard"), and setup never sees the keyboard.
///
/// The order tried, first reachable wins:
/// 1. `ZoneAppGroup` from the bundle's Info.plist, set from the `ZONE_APP_GROUP` build setting
///    (`Config/Signing.xcconfig`), so a build under any team names its own group;
/// 2. the original `group.wtf.zayd.zone`;
/// 3. the groups the embedded provisioning profile grants, which is what a re-signing tool
///    rewrites (AltStore and Sideloadly add the team to the group name).
public enum AppGroup {
    public static let defaultIdentifier = "group.wtf.zayd.zone"
    public static let infoKey = "ZoneAppGroup"

    /// The group for this process. Computed once; both processes run the same steps on the same
    /// signing, so they agree.
    public static let identifier: String = resolve(
        declared: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
        provisioned: embeddedProfileGroups(),
        reachable: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil })

    /// True when this process can actually use the shared container. False in the keyboard without
    /// Full Access, and in any build whose signing lost the group.
    ///
    /// Decided by writing a file, not by `isWritableFile(atPath:)` on the container's root: on iOS 27
    /// with a free team the root reads as not writable while `Library` inside it is, so the access()
    /// check said "unreachable" for a container both processes were using.
    public static var isReachable: Bool {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return false
        }
        return canWrite(in: url)
    }

    /// Writes and removes a small file under `Library/Caches` in the container. The keyboard without
    /// Full Access gets a container URL but no write, which this reports as false.
    public static func canWrite(in container: URL) -> Bool {
        let caches = container.appendingPathComponent("Library/Caches", isDirectory: true)
        let probe = caches.appendingPathComponent(".reach-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// What the reachability checks see, for the recording log.
    public static func diagnostics() -> [String: String] {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return ["group": identifier, "container": "nil"]
        }
        let library = url.appendingPathComponent("Library", isDirectory: true).path
        return ["group": identifier, "container": "ok",
                "rootAccessW": String(FileManager.default.isWritableFile(atPath: url.path)),
                "libraryAccessW": String(FileManager.default.isWritableFile(atPath: library)),
                "writeTest": String(canWrite(in: url))]
    }

    /// The first reachable candidate; with none reachable (the keyboard before Full Access), the one
    /// the build declared, so the answer is the right one once access arrives.
    public static func resolve(declared: String?, provisioned: [String], reachable: (String) -> Bool) -> String {
        var candidates: [String] = []
        for group in [declared, defaultIdentifier].compactMap({ $0 }) + provisioned
        where group.hasPrefix("group.") && !group.contains("$(") && !group.contains("*") && !candidates.contains(group) {
            candidates.append(group)
        }
        return candidates.first(where: reachable) ?? candidates.first ?? defaultIdentifier
    }

    /// `com.apple.security.application-groups` from a provisioning profile: a CMS envelope around an XML
    /// plist, which is read by finding the plist inside it.
    public static func provisionedGroups(fromProfile data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }

    /// App Store builds carry no profile; development, ad hoc and sideloaded ones do.
    private static func embeddedProfileGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return provisionedGroups(fromProfile: data)
    }
}
