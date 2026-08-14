import AudioToolbox
import AtomicGain
import Combine
import CoreAudio
import Foundation
import OSLog

@MainActor
final class AudioTapEngine: ObservableObject {
    @Published private(set) var state: MixerEngineState = .inactive
    var onStateChange: (@MainActor (MixerEngineState) -> Void)?
    var onLevelsChange: (@MainActor ([String: Float]) -> Void)?

    private let controller: AudioRouteController

    init() {
        let controller = AudioRouteController()
        self.controller = controller
        controller.onLevels = { [weak self] levels in
            Task { @MainActor in
                self?.onLevelsChange?(levels)
            }
        }
    }

    func checkSystemAudioPermission(completion: @escaping @MainActor (Bool) -> Void) {
        guard #available(macOS 14.2, *) else {
            completion(false)
            return
        }

        controller.requestSystemAudioPermission { granted in
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    func activate(completion: @escaping @MainActor (Bool) -> Void) {
        guard #available(macOS 14.2, *) else {
            setState(.unsupported)
            completion(false)
            return
        }

        setState(.requestingPermission)
        controller.requestSystemAudioPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.setState(granted ? .active : .permissionRequired)
                completion(granted)
            }
        }
    }

    func reconcile(targets: [RouteTarget], outputDeviceUID: String?) {
        guard case .active = state else { return }
        controller.reconcile(targets: targets, outputDeviceUID: outputDeviceUID) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.setState(.failed(error))
            }
        }
    }

    func stop() {
        controller.stopAll()
        setState(.inactive)
        onLevelsChange?([:])
    }

    private func setState(_ newState: MixerEngineState) {
        state = newState
        onStateChange?(newState)
    }
}

private final class AudioRouteController: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.ydps915.VolumeMixer.audio-route",
        qos: .userInitiated
    )
    private var routes: [String: ProcessTapRoute] = [:]
    private var levelTimer: DispatchSourceTimer?
    var onLevels: (@Sendable ([String: Float]) -> Void)?

    func requestSystemAudioPermission(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            guard #available(macOS 14.2, *) else {
                completion(false)
                return
            }

            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "Volume Mixer Permission Check"
            description.isPrivate = true
            description.muteBehavior = .unmuted

            var tapID = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            guard status == noErr, tapID != kAudioObjectUnknown else {
                AppLogger.audio.error("System audio permission probe failed: \(status, privacy: .public)")
                completion(false)
                return
            }

            _ = AudioHardwareDestroyProcessTap(tapID)
            completion(true)
        }
    }

    func reconcile(
        targets: [RouteTarget],
        outputDeviceUID: String?,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let error = self.apply(targets: targets, outputDeviceUID: outputDeviceUID)
            self.refreshLevelTimer()
            completion(error)
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            let existingRoutes = Array(self.routes.values)
            self.routes.removeAll()
            existingRoutes.forEach { $0.stop() }
            self.refreshLevelTimer()
        }
    }

    private func apply(targets: [RouteTarget], outputDeviceUID: String?) -> String? {
        guard #available(macOS 14.2, *) else {
            stopRoutes()
            return "O Volume Mixer requer macOS 14.2 ou posterior."
        }

        guard let outputDeviceUID else {
            stopRoutes()
            return "Nenhuma saída de áudio está disponível."
        }

        let desired = Dictionary(
            uniqueKeysWithValues: targets
                .filter { !$0.processObjectIDs.isEmpty }
                .map { ($0.id, $0) }
        )

        for id in routes.keys where desired[id] == nil {
            retireRoute(id: id)
        }

        var errors: [String] = []
        for (id, target) in desired {
            let mode: ProcessTapRouteMode = isUnity(target.gain) ? .monitoring : .mixing
            if let route = routes[id],
               route.processObjectIDs == target.processObjectIDs,
               route.outputDeviceUID == outputDeviceUID,
               route.mode == mode {
                route.setGain(target.gain)
                continue
            }

            retireRoute(id: id)
            guard let route = ProcessTapRoute(
                processObjectIDs: target.processObjectIDs,
                outputDeviceUID: outputDeviceUID,
                gain: target.gain,
                mode: mode
            ) else {
                errors.append(id)
                continue
            }
            routes[id] = route
        }

        if errors.isEmpty { return nil }
        return "Não foi possível criar a rota de áudio para: \(errors.sorted().joined(separator: ", "))."
    }

    private func retireRoute(id: String) {
        guard let route = routes.removeValue(forKey: id) else { return }
        route.setGain(1)
        route.stop()
    }

    private func stopRoutes() {
        let existingRoutes = Array(routes.values)
        routes.removeAll()
        existingRoutes.forEach { $0.stop() }
    }

    private func refreshLevelTimer() {
        guard !routes.isEmpty else {
            levelTimer?.cancel()
            levelTimer = nil
            onLevels?([:])
            return
        }

        guard levelTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self] in
            self?.publishLevels()
        }
        levelTimer = timer
        timer.resume()
    }

    private func publishLevels() {
        let levels = routes.reduce(into: [String: Float]()) { result, route in
            result[route.key] = route.value.consumeLevel()
        }
        onLevels?(levels)
    }

    private func isUnity(_ gain: Float) -> Bool {
        abs(gain - 1) < 0.001
    }
}

private enum ProcessTapRouteMode: Equatable, Sendable {
    case monitoring
    case mixing
}

private final class ProcessTapRoute: @unchecked Sendable {
    let processObjectIDs: [UInt32]
    let outputDeviceUID: String
    let mode: ProcessTapRouteMode

    private let gainState: RealtimeGain
    private let levelState = RealtimeGain(initialValue: 0)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    init?(
        processObjectIDs: [UInt32],
        outputDeviceUID: String,
        gain: Float,
        mode: ProcessTapRouteMode
    ) {
        guard #available(macOS 14.2, *),
              !processObjectIDs.isEmpty,
              AudioHardware.outputChannelCount(deviceUID: outputDeviceUID) == 2 else {
            return nil
        }

        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.mode = mode
        self.gainState = RealtimeGain(initialValue: gain)

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "Volume Mixer \(UUID().uuidString)"
        description.isPrivate = true
        description.muteBehavior = mode == .mixing ? .mutedWhenTapped : .unmuted

        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr,
              tapID != kAudioObjectUnknown,
              let format = AudioHardware.tapFormat(tapID: tapID),
              Self.supports(format: format) else {
            cleanUpFailedStart()
            return nil
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volume Mixer Route",
            kAudioAggregateDeviceUIDKey: "com.ydps915.VolumeMixer.route.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        guard AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        ) == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            cleanUpFailedStart()
            return nil
        }

        let gainState = gainState
        let levelState = levelState
        guard AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            nil,
            { _, inputData, _, outputData, _ in
                Self.render(
                    inputData: inputData,
                    outputData: outputData,
                    format: format,
                    gain: gainState.load(),
                    levelState: levelState,
                    shouldWriteOutput: mode == .mixing
                )
            }
        ) == noErr, let ioProcID else {
            cleanUpFailedStart()
            return nil
        }

        guard AudioDeviceStart(aggregateDeviceID, ioProcID) == noErr else {
            cleanUpFailedStart()
            return nil
        }
        isRunning = true
    }

    func setGain(_ gain: Float) {
        gainState.store(gain)
    }

    func consumeLevel() -> Float {
        let current = min(max(levelState.load(), 0), 1)
        // Keep the peak long enough for the UI to be readable between audio callbacks.
        levelState.store(current * 0.84)
        return current
    }

    func stop() {
        guard #available(macOS 14.2, *) else { return }

        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            if isRunning {
                _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
                isRunning = false
            }
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit {
        stop()
    }

    private func cleanUpFailedStart() {
        stop()
    }

    private static func supports(format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBytesPerFrame > 0 else {
            return false
        }
        let flags = format.mFormatFlags
        if flags & kAudioFormatFlagIsFloat != 0 {
            return format.mBitsPerChannel == 32 || format.mBitsPerChannel == 64
        }
        return flags & kAudioFormatFlagIsSignedInteger != 0
            && (format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32)
    }

    private static func render(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        gain: Float,
        levelState: RealtimeGain,
        shouldWriteOutput: Bool
    ) {
        levelState.store(peakLevel(inputData: inputData, format: format) * min(gain, 1))
        guard shouldWriteOutput else { return }

        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)

        for index in inputs.indices where index < outputs.count {
            var output = outputs[index]
            write(input: inputs[index], output: &output, format: format, gain: gain)
            outputs[index] = output
        }
    }

    private static func peakLevel(
        inputData: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription
    ) -> Float {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let flags = format.mFormatFlags
        var peak: Float = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
                let values = data.assumingMemoryBound(to: Float.self)
                for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                    peak = max(peak, abs(values[index]))
                }
            } else if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 64 {
                let values = data.assumingMemoryBound(to: Double.self)
                for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Double>.size) {
                    peak = max(peak, Float(abs(values[index])))
                }
            } else if format.mBitsPerChannel == 16 {
                let values = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size) {
                    peak = max(peak, abs(Float(values[index])) / 32_768)
                }
            } else if format.mBitsPerChannel == 32 {
                let values = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size) {
                    peak = max(peak, Float(abs(Double(values[index])) / 2_147_483_648))
                }
            }
        }
        return min(peak, 1)
    }

    private static func write(
        input: AudioBuffer,
        output: inout AudioBuffer,
        format: AudioStreamBasicDescription,
        gain: Float
    ) {
        guard let source = input.mData, let destination = output.mData else { return }
        let byteCount = min(input.mDataByteSize, output.mDataByteSize)
        guard byteCount > 0 else { return }
        output.mDataByteSize = byteCount

        let flags = format.mFormatFlags
        if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
            scaleFloat32(source: source, destination: destination, byteCount: byteCount, gain: gain)
        } else if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 64 {
            scaleFloat64(source: source, destination: destination, byteCount: byteCount, gain: gain)
        } else if format.mBitsPerChannel == 16 {
            scaleInt16(source: source, destination: destination, byteCount: byteCount, gain: gain)
        } else if format.mBitsPerChannel == 32 {
            scaleInt32(source: source, destination: destination, byteCount: byteCount, gain: gain)
        }
    }

    private static func scaleFloat32(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        byteCount: UInt32,
        gain: Float
    ) {
        let input = source.assumingMemoryBound(to: Float.self)
        let output = destination.assumingMemoryBound(to: Float.self)
        for index in 0..<(Int(byteCount) / MemoryLayout<Float>.size) {
            output[index] = input[index] * gain
        }
    }

    private static func scaleFloat64(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        byteCount: UInt32,
        gain: Float
    ) {
        let input = source.assumingMemoryBound(to: Double.self)
        let output = destination.assumingMemoryBound(to: Double.self)
        for index in 0..<(Int(byteCount) / MemoryLayout<Double>.size) {
            output[index] = input[index] * Double(gain)
        }
    }

    private static func scaleInt16(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        byteCount: UInt32,
        gain: Float
    ) {
        let input = source.assumingMemoryBound(to: Int16.self)
        let output = destination.assumingMemoryBound(to: Int16.self)
        for index in 0..<(Int(byteCount) / MemoryLayout<Int16>.size) {
            output[index] = Int16(clamping: Int(Float(input[index]) * gain))
        }
    }

    private static func scaleInt32(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        byteCount: UInt32,
        gain: Float
    ) {
        let input = source.assumingMemoryBound(to: Int32.self)
        let output = destination.assumingMemoryBound(to: Int32.self)
        for index in 0..<(Int(byteCount) / MemoryLayout<Int32>.size) {
            output[index] = Int32(clamping: Int64(Double(input[index]) * Double(gain)))
        }
    }
}

private final class RealtimeGain: @unchecked Sendable {
    private let storage: OpaquePointer

    init(initialValue: Float) {
        storage = VMAtomicGainCreate(Self.clamped(initialValue))
    }

    func store(_ value: Float) {
        VMAtomicGainStore(storage, Self.clamped(value))
    }

    func load() -> Float {
        VMAtomicGainLoad(storage)
    }

    deinit {
        VMAtomicGainDestroy(storage)
    }

    private static func clamped(_ value: Float) -> Float {
        min(max(value, 0), 2)
    }
}
