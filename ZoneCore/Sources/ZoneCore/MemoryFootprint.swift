// by zayd/cold @ zayd.wtf

import Darwin
import Foundation

/// The process's memory as jetsam counts it. A keyboard extension is killed when its physical
/// footprint passes a limit far below an app's (the keyboard goes blank, or iOS swaps in its
/// own), so the keyboard writes this to the recording log on each appearance.
public enum MemoryFootprint {
    /// `phys_footprint` from `TASK_VM_INFO`, the number jetsam reports and kills on, in bytes.
    public static func current() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Bytes left before the process's jetsam limit, nil where the system gives no limit
    /// (the simulator, macOS).
    public static func available() -> UInt64? {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        let bytes = os_proc_available_memory()
        return bytes > 0 ? UInt64(bytes) : nil
        #else
        return nil
        #endif
    }

    /// Whole megabytes (MiB, as Xcode and jetsam reports show them).
    public static func megabytes(_ bytes: UInt64) -> String {
        String(bytes / 1_048_576)
    }

    /// The recording log's fields: `mb` always, `limitMB` (footprint plus what is left) when the
    /// system reports a limit. No text, nothing about the host.
    public static func journalFields() -> [String: String] {
        guard let footprint = current() else { return [:] }
        var fields = ["mb": megabytes(footprint)]
        if let left = available() { fields["limitMB"] = megabytes(footprint + left) }
        return fields
    }
}
