import CoreAudio
import XCTest
@testable import VolumeMixer

/// The tap and the output device have independent formats. These cover the
/// mapping that used to be a straight buffer-to-buffer copy, which crossed
/// channels and truncated buffers whenever the two disagreed.
final class RenderPlanTests: XCTestCase {
    private func format(
        sampleRate: Double = 48_000,
        channels: UInt32 = 2,
        interleaved: Bool = true,
        isFloat: Bool = true,
        bits: UInt32 = 32
    ) -> AudioStreamBasicDescription {
        var flags = isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerChannel = bits / 8
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: interleaved ? bytesPerChannel * channels : bytesPerChannel,
            mFramesPerPacket: 1,
            mBytesPerFrame: interleaved ? bytesPerChannel * channels : bytesPerChannel,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bits,
            mReserved: 0
        )
    }

    func testRejectsFormatsItCannotRenderCorrectly() {
        // Declining is the point: the route is not built, so the app keeps
        // playing normally instead of being muted behind a broken renderer.
        XCTAssertNil(RenderPlan(tapFormat: format(isFloat: false), deviceFormat: format()))
        XCTAssertNil(RenderPlan(tapFormat: format(), deviceFormat: format(isFloat: false)))
        XCTAssertNil(RenderPlan(tapFormat: format(isFloat: false, bits: 16), deviceFormat: format()))
        XCTAssertNil(RenderPlan(tapFormat: format(channels: 0), deviceFormat: format()))
    }

    func testAcceptsMismatchedSampleRates() {
        // A 48 kHz tap into a 44.1 kHz Bluetooth headset is the common case; the
        // HAL reconciles the rate, the plan only has to map channels.
        let plan = RenderPlan(
            tapFormat: format(sampleRate: 48_000),
            deviceFormat: format(sampleRate: 44_100)
        )
        XCTAssertNotNil(plan)
    }

    func testInterleavedStereoMapsChannelsInPlace() {
        let plan = RenderPlan(tapFormat: format(), deviceFormat: format())!
        XCTAssertEqual(plan.inputLocation(forChannel: 0).stride, 2)
        XCTAssertEqual(plan.inputLocation(forChannel: 1).offset, 1)
        XCTAssertEqual(plan.outputLocation(forChannel: 1).buffer, 0)
    }

    func testNonInterleavedUsesOneBufferPerChannel() {
        let plan = RenderPlan(
            tapFormat: format(interleaved: false),
            deviceFormat: format(interleaved: false)
        )!
        XCTAssertEqual(plan.inputLocation(forChannel: 1).buffer, 1)
        XCTAssertEqual(plan.inputLocation(forChannel: 1).stride, 1)
        XCTAssertEqual(plan.inputLocation(forChannel: 1).offset, 0)
    }

    func testMonoTapFeedsEveryOutputChannel() {
        let plan = RenderPlan(
            tapFormat: format(channels: 1),
            deviceFormat: format(channels: 2)
        )!
        // Without this a mono tap was audible only on the left speaker.
        XCTAssertEqual(plan.sourceChannel(forOutputChannel: 0), 0)
        XCTAssertEqual(plan.sourceChannel(forOutputChannel: 1), 0)
    }

    func testFrameCountsAccountForInterleaving() {
        let interleaved = RenderPlan(tapFormat: format(), deviceFormat: format())!
        // 8 stereo interleaved frames = 16 floats = 64 bytes.
        XCTAssertEqual(interleaved.inputFrames(byteCountOfFirstBuffer: 64), 8)

        let planar = RenderPlan(
            tapFormat: format(interleaved: false),
            deviceFormat: format(interleaved: false)
        )!
        // The same 64 bytes in one planar channel buffer is 16 frames.
        XCTAssertEqual(planar.inputFrames(byteCountOfFirstBuffer: 64), 16)
    }

    /// Runs the plan's arithmetic over real arrays: planar stereo in, interleaved
    /// stereo out. The old code copied buffer 0 to buffer 0 and produced left
    /// channel data at double speed with a silent tail.
    func testPlanarTapCopiesCorrectlyIntoAnInterleavedDevice() {
        let plan = RenderPlan(
            tapFormat: format(interleaved: false),
            deviceFormat: format()
        )!
        let frames = 4
        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [-1, -2, -3, -4]
        let inputs = [left, right]
        var output = [Float](repeating: .nan, count: frames * 2)

        for channel in 0..<plan.outputChannels {
            let source = plan.inputLocation(forChannel: plan.sourceChannel(forOutputChannel: channel))
            let destination = plan.outputLocation(forChannel: channel)
            for frame in 0..<frames {
                output[destination.offset + frame * destination.stride] =
                    inputs[source.buffer][source.offset + frame * source.stride]
            }
        }

        XCTAssertEqual(output, [1, -1, 2, -2, 3, -3, 4, -4])
    }
}
