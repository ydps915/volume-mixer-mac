import CoreAudio
import Foundation

/// How one tap's buffers map onto the output device's buffers.
///
/// The tap and the device are **separate streams with separate formats**. A
/// Bluetooth headset commonly runs at 44.1 kHz while the system mixdown a tap
/// delivers is 48 kHz, and either side may be interleaved or not. The engine
/// used to interpret the device's output buffers with the *tap's* format
/// description and copy buffer N to buffer N, which silently truncated buffers
/// and crossed channels whenever the two disagreed — heard as distortion, a
/// "filtered" sound, or half-speed audio.
///
/// Building the plan up front also means an unrenderable combination is caught
/// before the tap is installed, so the route is declined and the app keeps
/// playing normally instead of being muted behind a broken renderer.
struct RenderPlan: Equatable, Sendable {
    let inputChannels: Int
    let outputChannels: Int
    let inputIsInterleaved: Bool
    let outputIsInterleaved: Bool

    /// Returns `nil` when the pair cannot be rendered correctly.
    ///
    /// Only 32-bit float is accepted. It is what process taps deliver and what
    /// device virtual formats use; accepting more formats previously meant
    /// hand-rolled conversion paths that were wrong whenever the two sides
    /// disagreed, and being wrong here is worse than declining the route.
    init?(tapFormat: AudioStreamBasicDescription, deviceFormat: AudioStreamBasicDescription) {
        guard Self.isFloat32LinearPCM(tapFormat), Self.isFloat32LinearPCM(deviceFormat) else {
            return nil
        }
        let inputChannels = Int(tapFormat.mChannelsPerFrame)
        let outputChannels = Int(deviceFormat.mChannelsPerFrame)
        guard inputChannels >= 1, outputChannels >= 1 else { return nil }

        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.inputIsInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        self.outputIsInterleaved = deviceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }

    /// A tap that carries fewer channels than the device feeds its last channel
    /// to the remaining outputs, so a mono tap is heard on both speakers rather
    /// than only the left one.
    func sourceChannel(forOutputChannel channel: Int) -> Int {
        min(channel, inputChannels - 1)
    }

    /// Buffer index and sample stride for one channel of an audio buffer list.
    func inputLocation(forChannel channel: Int) -> (buffer: Int, offset: Int, stride: Int) {
        inputIsInterleaved
            ? (buffer: 0, offset: channel, stride: inputChannels)
            : (buffer: channel, offset: 0, stride: 1)
    }

    func outputLocation(forChannel channel: Int) -> (buffer: Int, offset: Int, stride: Int) {
        outputIsInterleaved
            ? (buffer: 0, offset: channel, stride: outputChannels)
            : (buffer: channel, offset: 0, stride: 1)
    }

    /// Frames held by a buffer list under this plan's input layout.
    func inputFrames(byteCountOfFirstBuffer byteCount: Int) -> Int {
        let samples = byteCount / MemoryLayout<Float>.size
        return inputIsInterleaved ? samples / inputChannels : samples
    }

    func outputFrames(byteCountOfFirstBuffer byteCount: Int) -> Int {
        let samples = byteCount / MemoryLayout<Float>.size
        return outputIsInterleaved ? samples / outputChannels : samples
    }

    private static func isFloat32LinearPCM(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }
}
