// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class ModelDownloadBarrierTests: XCTestCase {
    private let model = URL(fileURLWithPath: "/old/Library/Application Support/Models/fluid")
    private var file: URL { model.appendingPathComponent("Encoder/weights") }

    func testDeletionBlocksOldCallbacksAcrossRelaunchAndAllowsExplicitRedownload() {
        var barrier = ModelDownloadBarrier()
        XCTAssertFalse(barrier.blocks(file, generation: nil))
        barrier.retire([model])
        XCTAssertTrue(barrier.blocks(file, generation: nil))
        let saved = barrier.generations
        let restored = ModelDownloadBarrier(generations: saved)
        let moved = URL(fileURLWithPath: "/new/Library/Application Support/Models/fluid/Encoder/weights")
        XCTAssertTrue(restored.blocks(moved, generation: nil))
        let explicitDownload = restored.generation(for: moved)
        XCTAssertNotNil(explicitDownload)
        XCTAssertFalse(restored.blocks(moved, generation: explicitDownload))
        barrier.retire([model])
        XCTAssertTrue(barrier.blocks(file, generation: explicitDownload), "another delete revokes the preceding download")
    }

    func testUnrelatedModelAndPrefixSiblingStayWritable() {
        var barrier = ModelDownloadBarrier()
        barrier.retire([model])
        for name in ["fluid-pro", "speakers", "recordings"] {
            let other = model.deletingLastPathComponent().appendingPathComponent(name).appendingPathComponent("weights")
            XCTAssertFalse(barrier.blocks(other, generation: nil))
        }
    }
}
