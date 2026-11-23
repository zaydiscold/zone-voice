// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class MemoryFootprintTests: XCTestCase {
    func testFootprintIsReadAndGrowsWithDirtyMemory() throws {
        let before = try XCTUnwrap(MemoryFootprint.current())
        XCTAssertGreaterThan(before, 1_048_576, "a running test process has more than 1 MB of footprint")
        // 32 MB written page by page is dirty memory, which phys_footprint must count.
        let size = 32 * 1_048_576
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { buffer.deallocate() }
        for offset in stride(from: 0, to: size, by: 4_096) { buffer.storeBytes(of: UInt8(1), toByteOffset: offset, as: UInt8.self) }
        let after = try XCTUnwrap(MemoryFootprint.current())
        XCTAssertGreaterThan(after, before + UInt64(size) / 2)
    }

    func testJournalFieldsAreWholeMegabytesAndNothingElse() throws {
        let fields = MemoryFootprint.journalFields()
        let mb = try XCTUnwrap(fields["mb"].flatMap(Int.init))
        XCTAssertGreaterThan(mb, 0)
        XCTAssertTrue(Set(fields.keys).isSubset(of: ["mb", "limitMB"]))
        if let limit = fields["limitMB"].flatMap(Int.init) { XCTAssertGreaterThanOrEqual(limit, mb) }
        XCTAssertEqual(MemoryFootprint.megabytes(3 * 1_048_576 + 5), "3")
    }
}
