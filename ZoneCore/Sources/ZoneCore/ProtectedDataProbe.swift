// by zayd/cold @ zayd.wtf

import Foundation

/// Whether this process can read files protected until the first unlock, the class every Zone
/// file and both preference stores use. After a restart, iOS can start Zone in the background
/// (prewarming, a Watch transfer, a download finishing) before the person has unlocked once.
/// Until then every preference reads as missing: a Zone built then ran on the defaults, violet
/// and the Chime cue, for the whole life of the process (2026-11-19, Zayd's phone after a
/// restart). A write then can also land over the real record.
///
/// `UIApplication.isProtectedDataAvailable` is not the test: it follows the stricter class that
/// locks again every time the screen locks, while these files stay readable from the first
/// unlock to the next restart. So the probe reads a small file of the same class.
public struct ProtectedDataProbe: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The probe in Application Support, beside the app's other files.
    public static var standard: ProtectedDataProbe {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ProtectedDataProbe(url: support.appendingPathComponent("protected-data-probe"))
    }

    /// True when the probe reads, or is written for the first time. False only for the refusal a
    /// locked class key gives (a permission error): any other failure, a full disk say, must not
    /// keep Zone from starting.
    public func isAvailable() -> Bool {
        do {
            _ = try Data(contentsOf: url)
            return true
        } catch where Self.isProtectionRefusal(error) {
            return false
        } catch {
            // Missing: the first launch of a build that has the probe.
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                #if os(iOS)
                try Data("zone".utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try Data("zone".utf8).write(to: url, options: .atomic)
                #endif
                return true
            } catch {
                return !Self.isProtectionRefusal(error)
            }
        }
    }

    /// A locked data-protection class refuses with EPERM, which Foundation reports as a
    /// no-permission file error. EACCES reads the same way and is treated alike.
    static func isProtectionRefusal(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isProtectionRefusal(underlying) }
        return false
    }
}
