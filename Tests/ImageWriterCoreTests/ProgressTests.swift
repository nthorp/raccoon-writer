import Foundation
import Testing
@testable import ImageWriterCore

struct SpeedEstimatorTests {
    @Test func unknownUntilAFullWindow() {
        var speed = SpeedEstimator(startTime: 10)
        speed.record(totalBytes: 500_000, at: 10.5)
        speed.record(totalBytes: 900_000, at: 10.99)
        #expect(speed.bytesPerSecond == nil)
        speed.record(totalBytes: 1_000_000, at: 11)
        #expect(speed.bytesPerSecond == 1_000_000)
    }

    @Test func steadyRateStaysExact() {
        var speed = SpeedEstimator(startTime: 0)
        for second in 1...5 {
            speed.record(totalBytes: UInt64(second) * 8_000_000, at: TimeInterval(second))
        }
        #expect(speed.bytesPerSecond == 8_000_000)
    }

    @Test func rateChangeIsSmoothed() throws {
        var speed = SpeedEstimator(startTime: 0)
        speed.record(totalBytes: 10_000_000, at: 1)
        speed.record(totalBytes: 30_000_000, at: 2)
        // 0.3 × 20 MB/s + 0.7 × 10 MB/s
        #expect(abs(try #require(speed.bytesPerSecond) - 13_000_000) < 1)
        for second in 3...30 {
            speed.record(totalBytes: 30_000_000 + UInt64(second - 2) * 20_000_000, at: TimeInterval(second))
        }
        #expect(abs(try #require(speed.bytesPerSecond) - 20_000_000) < 1_000)
    }

    @Test func slowSampleClosesALongWindow() {
        // One chunk that took 2.5 s: the window spans it rather than waiting for another sample.
        var speed = SpeedEstimator(startTime: 0)
        speed.record(totalBytes: 5_000_000, at: 2.5)
        #expect(speed.bytesPerSecond == 2_000_000)
    }

    @Test func bytesGoingBackwardsAreIgnored() {
        var speed = SpeedEstimator(startTime: 0, startBytes: 1_000)
        speed.record(totalBytes: 500, at: 2)
        #expect(speed.bytesPerSecond == nil)
    }
}

struct TransferProgressTests {
    @Test func fractionAndRemainingTime() {
        let progress = TransferProgress(completedBytes: 250, totalBytes: 1_000, bytesPerSecond: 50)
        #expect(progress.fractionComplete == 0.25)
        #expect(progress.estimatedSecondsRemaining == 15)
    }

    @Test func remainingTimeUnknownWithoutSpeed() {
        #expect(TransferProgress(completedBytes: 1, totalBytes: 10, bytesPerSecond: nil).estimatedSecondsRemaining == nil)
        #expect(TransferProgress(completedBytes: 1, totalBytes: 10, bytesPerSecond: 0).estimatedSecondsRemaining == nil)
    }

    @Test func completeHasNoTimeRemaining() {
        let progress = TransferProgress(completedBytes: 10, totalBytes: 10, bytesPerSecond: nil)
        #expect(progress.fractionComplete == 1)
        #expect(progress.estimatedSecondsRemaining == 0)
    }

    @Test func emptyTotalCountsAsComplete() {
        #expect(TransferProgress(completedBytes: 0, totalBytes: 0, bytesPerSecond: nil).fractionComplete == 1)
    }
}

struct ProgressMeterTests {
    @Test func throttlesToTenPerSecondButAlwaysPublishesFirstAndLast() {
        var meter = ProgressMeter(totalBytes: 1_000, startTime: 0)
        #expect(meter.update(completedBytes: 0, at: 0)?.completedBytes == 0)
        #expect(meter.update(completedBytes: 100, at: 0.05) == nil)
        #expect(meter.update(completedBytes: 200, at: 0.1)?.completedBytes == 200)
        #expect(meter.update(completedBytes: 300, at: 0.15) == nil)
        #expect(meter.update(completedBytes: 1_000, at: 0.16)?.completedBytes == 1_000)
    }

    @Test func carriesTheSmoothedSpeed() {
        var meter = ProgressMeter(totalBytes: 10_000, startTime: 0)
        #expect(meter.update(completedBytes: 0, at: 0)?.bytesPerSecond == nil)
        #expect(meter.update(completedBytes: 4_000, at: 1)?.bytesPerSecond == 4_000)
    }
}
