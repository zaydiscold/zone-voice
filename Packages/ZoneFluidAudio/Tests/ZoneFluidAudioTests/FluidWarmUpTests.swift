// by zayd/cold @ zayd.wtf

import FluidAudio
import XCTest
@testable import ZoneFluidAudio

final class FluidWarmUpTests: XCTestCase {
    /// A warm-up FluidAudio rejects runs no model and leaves the program cold.
    func testTheWarmUpReachesTheModel() {
        XCTAssertTrue(FluidWarmUp.reachesTheModel)
    }

    /// The numbers the warm-up's length rests on. If FluidAudio changes its minimum or its window,
    /// measure the warm-up again (scripts/model-lab, `warmup`).
    func testFluidAudioStillPadsShortAudioToOneWindow() {
        XCTAssertEqual(ASRConstants.minimumRequiredSamples(forSampleRate: 16_000), 4_800)
        XCTAssertEqual(ASRConstants.maxModelSamples, 240_000)
        XCTAssertLessThan(2_560, ASRConstants.minimumRequiredSamples(forSampleRate: 16_000),
                          "a 2,560-sample warm-up is rejected before the model runs")
    }
}
