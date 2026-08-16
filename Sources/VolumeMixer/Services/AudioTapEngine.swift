import Accelerate
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
    var onRoutingIssueChange: (@MainActor (String?) -> Void)?

    private let controller: AudioRouteController
    /// Guards against an in-flight activation landing after the user switched
    /// the mixer off again.
    private var activationGeneration = 0

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

        activationGeneration += 1
        let generation = activationGeneration
        setState(.requestingPermission)
        controller.requestSystemAudioPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, generation == self.activationGeneration else { return }
                self.setState(granted ? .active : .permissionRequired)
                completion(granted)
            }
        }
    }

    func reconcile(targets: [RouteTarget], outputDeviceUID: String?) {
        guard case .active = state else { return }
        controller.reconcile(targets: targets, outputDeviceUID: outputDeviceUID) { [weak self] issue in
            Task { @MainActor in
                self?.onRoutingIssueChange?(issue)
            }
        }
    }

    func stop() {
        activationGeneration += 1
        controller.stopAll()
        setState(.inactive)
        onLevelsChange?([:])
        onRoutingIssueChange?(nil)
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
    /// Once an app has been attenuated it keeps its mixing route even when the
    /// user returns it to exactly 100%. Rebuilding the tap on every crossing of
    /// 1.0 tore the route down mid-drag, which is audible as a pop and a brief
    /// jump back to full volume.
    private var mixingTargetIDs: Set<String> = []
    private var retryNotBefore: [String: Date] = [:]
    private var heldLevels: [String: Float] = [:]
    private var lastReconcileSummary: String?
    private var levelTimer: DispatchSourceTimer?
    var onLevels: (@Sendable ([String: Float]) -> Void)?

    private static let retryCooldown: TimeInterval = 5

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

            // Reconciles run on every hardware event and every recovery scan, so
            // only a change is worth a log line.
            let summary = "targets=\(targets.count) routes=\(self.routes.count) issue=\(error ?? "none")"
            if summary != self.lastReconcileSummary {
                self.lastReconcileSummary = summary
                AppLogger.audio.notice(
                    "reconcile \(summary, privacy: .public) output=\(outputDeviceUID ?? "nil", privacy: .public)"
                )
            }
            completion(error)
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            let existingRoutes = Array(self.routes.values)
            self.routes.removeAll()
            self.mixingTargetIDs.removeAll()
            self.retryNotBefore.removeAll()
            self.heldLevels.removeAll()
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
        // A target that is gone entirely starts fresh next time, back on the
        // lighter monitoring path.
        mixingTargetIDs.formIntersection(desired.keys)
        retryNotBefore = retryNotBefore.filter { desired[$0.key] != nil }

        let now = Date()
        var failures: [RouteTarget] = []

        for (id, target) in desired {
            let needsMixing = !isUnity(target.gain) || mixingTargetIDs.contains(id)
            let mode: ProcessTapRouteMode = needsMixing ? .mixing : .monitoring

            if let route = routes[id],
               route.processObjectIDs == target.processObjectIDs,
               route.outputDeviceUID == outputDeviceUID,
               route.mode == mode {
                route.setGain(target.gain)
                route.setLimitsPeaks(target.limitPeaks)
                continue
            }

            // Do not hammer Core Audio with tap creation for a target that just
            // failed; it retries on every hardware event and every rescan.
            if let notBefore = retryNotBefore[id], now < notBefore {
                if needsMixing { failures.append(target) }
                continue
            }

            retireRoute(id: id)
            guard let route = ProcessTapRoute(
                processObjectIDs: target.processObjectIDs,
                outputDeviceUID: outputDeviceUID,
                gain: target.gain,
                limitPeaks: target.limitPeaks,
                mode: mode
            ) else {
                retryNotBefore[id] = now.addingTimeInterval(Self.retryCooldown)
                // A failed monitoring route only costs a level meter, so it is
                // not worth an error banner.
                if needsMixing { failures.append(target) }
                continue
            }

            retryNotBefore.removeValue(forKey: id)
            if needsMixing { mixingTargetIDs.insert(id) }
            routes[id] = route
        }

        guard !failures.isEmpty else { return nil }
        return Self.failureMessage(for: failures, outputDeviceUID: outputDeviceUID)
    }

    private static func failureMessage(
        for failures: [RouteTarget],
        outputDeviceUID: String
    ) -> String {
        let names = failures.map(\.displayName).sorted().joined(separator: ", ")
        if AudioHardware.outputChannelCount(deviceUID: outputDeviceUID) != 2 {
            return "A saída selecionada não é estéreo. Esta versão só ajusta o volume por app em saídas estéreo, então \(names) continua na saída padrão."
        }
        return "Não foi possível ajustar agora: \(names). O áudio continua na saída padrão e o mixer tentará de novo."
    }

    private func retireRoute(id: String) {
        guard let route = routes.removeValue(forKey: id) else { return }
        // Deliberately no gain reset here: restoring unity on a route that is
        // about to be destroyed made a muted app blast one buffer at full
        // volume before the tap went away.
        route.stop()
        heldLevels.removeValue(forKey: id)
    }

    private func stopRoutes() {
        let existingRoutes = Array(routes.values)
        routes.removeAll()
        mixingTargetIDs.removeAll()
        heldLevels.removeAll()
        existingRoutes.forEach { $0.stop() }
    }

    private func refreshLevelTimer() {
        guard !routes.isEmpty else {
            levelTimer?.cancel()
            levelTimer = nil
            heldLevels.removeAll()
            onLevels?([:])
            return
        }

        guard levelTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.publishLevels()
        }
        levelTimer = timer
        timer.resume()
    }

    /// Peak hold lives here rather than in the route so that draining a peak is
    /// a single atomic exchange, with no read-modify-write racing the render
    /// thread.
    private func publishLevels() {
        var levels: [String: Float] = [:]
        for (id, route) in routes {
            let peak = route.consumeLevel()
            levels[id] = max(peak, (heldLevels[id] ?? 0) * 0.72)
        }
        heldLevels = levels
        onLevels?(levels)
    }

    private func isUnity(_ gain: Float) -> Bool {
        abs(gain - 1) < 0.001
    }
}

private enum ProcessTapRouteMode: Equatable, Sendable {
    /// Meter only. The app keeps playing through the normal system route and the
    /// aggregate device carries no output sub-device, so it cannot disturb the
    /// physical output.
    case monitoring
    /// The app is muted at the system level and this route renders its audio.
    case mixing
}

private final class ProcessTapRoute: @unchecked Sendable {
    let processObjectIDs: [UInt32]
    let outputDeviceUID: String
    let mode: ProcessTapRouteMode

    private let gainState: RealtimeGain
    private let levelState = RealtimeGain(initialValue: 0)
    /// 0 or 1. An atomic flag so the setting can be toggled without rebuilding
    /// the tap, which would be audible.
    private let limitPeaksState: RealtimeGain
    /// Only ever touched from the render callback, so a plain reference is fine.
    private let limiterState = LimiterState()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    init?(
        processObjectIDs: [UInt32],
        outputDeviceUID: String,
        gain: Float,
        limitPeaks: Bool,
        mode: ProcessTapRouteMode
    ) {
        self.limitPeaksState = RealtimeGain(initialValue: limitPeaks ? 1 : 0)
        guard #available(macOS 14.2, *), !processObjectIDs.isEmpty else { return nil }
        // Only a mixing route writes to the device, so only it needs a stereo
        // output. Metering works on any output.
        if mode == .mixing {
            let channels = AudioHardware.outputChannelCount(deviceUID: outputDeviceUID)
            guard channels == 2 else {
                AppLogger.audio.error(
                    "Route rejected: output \(outputDeviceUID, privacy: .public) has \(channels ?? -1, privacy: .public) channels"
                )
                return nil
            }
        }

        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.mode = mode
        self.gainState = RealtimeGain(initialValue: gain)

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "Volume Mixer \(UUID().uuidString)"
        description.isPrivate = true
        description.muteBehavior = mode == .mixing ? .mutedWhenTapped : .unmuted

        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            AppLogger.audio.error("Tap creation failed: \(tapStatus, privacy: .public)")
            stop()
            return nil
        }
        guard let format = AudioHardware.tapFormat(tapID: tapID), Self.supports(format: format) else {
            AppLogger.audio.error("Unsupported tap format for \(processObjectIDs, privacy: .public)")
            stop()
            return nil
        }

        if mode == .mixing {
            guard Self.createAggregateDevice(
                tapUID: description.uuid.uuidString,
                outputDeviceUID: outputDeviceUID,
                into: &aggregateDeviceID
            ) else {
                stop()
                return nil
            }
        } else {
            // Prefer a tap-only device. Fall back to attaching the output so a
            // host that rejects a sub-device-less aggregate still gets a meter.
            let created = Self.createAggregateDevice(
                tapUID: description.uuid.uuidString,
                outputDeviceUID: nil,
                into: &aggregateDeviceID
            ) || Self.createAggregateDevice(
                tapUID: description.uuid.uuidString,
                outputDeviceUID: outputDeviceUID,
                into: &aggregateDeviceID
            )
            guard created else {
                stop()
                return nil
            }
        }

        let gainState = gainState
        let levelState = levelState
        let limitPeaksState = limitPeaksState
        let limiterState = limiterState
        let shouldWriteOutput = mode == .mixing
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
                    limitsPeaks: limitPeaksState.load() > 0.5,
                    limiterState: limiterState,
                    levelState: levelState,
                    shouldWriteOutput: shouldWriteOutput
                )
            }
        ) == noErr, let ioProcID else {
            AppLogger.audio.error("IOProc creation failed for aggregate \(self.aggregateDeviceID, privacy: .public)")
            stop()
            return nil
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else {
            AppLogger.audio.error("AudioDeviceStart failed: \(startStatus, privacy: .public)")
            stop()
            return nil
        }
        isRunning = true
    }

    @available(macOS 14.2, *)
    private static func createAggregateDevice(
        tapUID: String,
        outputDeviceUID: String?,
        into aggregateDeviceID: inout AudioObjectID
    ) -> Bool {
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volume Mixer Route",
            kAudioAggregateDeviceUIDKey: "com.ydps915.VolumeMixer.route.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        if let outputDeviceUID {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outputDeviceUID],
            ]
        } else {
            // Tap-only: the tap provides the clock. A metering route used to
            // attach the physical output too, which meant every app playing at
            // 100% added another aggregate device driving the real output.
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [[String: Any]]()
        }

        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard status == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            AppLogger.audio.error("Aggregate device creation failed: \(status, privacy: .public)")
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        return true
    }

    func setGain(_ gain: Float) {
        gainState.store(gain)
    }

    func setLimitsPeaks(_ limitPeaks: Bool) {
        limitPeaksState.store(limitPeaks ? 1 : 0)
    }

    /// Drains the peak accumulated since the last call.
    func consumeLevel() -> Float {
        min(max(levelState.exchange(0), 0), 1)
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
        limitsPeaks: Bool,
        limiterState: LimiterState,
        levelState: RealtimeGain,
        shouldWriteOutput: Bool
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)

        let peak = peakLevel(inputs: inputs, format: format)

        var targetGain = gain
        if limitsPeaks {
            targetGain = limiterState.limiter.nextGain(
                inputPeak: peak,
                gain: gain,
                bufferDuration: bufferDuration(inputs: inputs, format: format)
            )
        } else {
            limiterState.limiter = PeakLimiter()
        }

        // Report what the user actually hears, so the meter shows the limiter
        // holding the level rather than pinning red.
        levelState.storeMax(min(peak * targetGain, 1))

        guard shouldWriteOutput else {
            // An untouched output buffer is not guaranteed to be silent.
            for index in outputs.indices {
                silence(outputs[index])
            }
            limiterState.appliedGain = targetGain
            return
        }

        // Ramp from the gain the previous buffer ended on, so the limiter moving
        // is not audible as a click at the buffer boundary.
        //
        // Except when attacking: ramping *down* would apply the older, higher
        // gain to the very samples that triggered the reduction, letting the
        // transient clip. Dropping straight to the new gain is inaudible under a
        // loud passage, whereas the clipping it prevents is not.
        let startGain = min(limiterState.appliedGain, targetGain)
        limiterState.appliedGain = targetGain

        for index in outputs.indices {
            if index < inputs.count {
                write(
                    input: inputs[index],
                    output: outputs[index],
                    format: format,
                    startGain: startGain,
                    endGain: targetGain
                )
            } else {
                silence(outputs[index])
            }
        }
    }

    private static func bufferDuration(
        inputs: UnsafeMutableAudioBufferListPointer,
        format: AudioStreamBasicDescription
    ) -> Float {
        guard format.mSampleRate > 0,
              format.mBytesPerFrame > 0,
              let first = inputs.first else {
            return 0.01
        }
        let frames = Float(first.mDataByteSize) / Float(format.mBytesPerFrame)
        return frames / Float(format.mSampleRate)
    }

    private static func silence(_ buffer: AudioBuffer) {
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
        memset(data, 0, Int(buffer.mDataByteSize))
    }

    private static func peakLevel(
        inputs: UnsafeMutableAudioBufferListPointer,
        format: AudioStreamBasicDescription
    ) -> Float {
        let flags = format.mFormatFlags
        var peak: Float = 0

        for buffer in inputs {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }

            if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
                let count = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                guard count > 0 else { continue }
                var bufferPeak: Float = 0
                vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, count)
                peak = max(peak, bufferPeak)
            } else if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 64 {
                let count = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Double>.size)
                guard count > 0 else { continue }
                var bufferPeak: Double = 0
                vDSP_maxmgvD(data.assumingMemoryBound(to: Double.self), 1, &bufferPeak, count)
                peak = max(peak, Float(bufferPeak))
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
        output: AudioBuffer,
        format: AudioStreamBasicDescription,
        startGain: Float,
        endGain: Float
    ) {
        guard let source = input.mData, let destination = output.mData else { return }
        let byteCount = min(input.mDataByteSize, output.mDataByteSize)
        guard byteCount > 0 else {
            silence(output)
            return
        }

        let flags = format.mFormatFlags
        if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
            scaleFloat32(
                source: source,
                destination: destination,
                byteCount: byteCount,
                startGain: startGain,
                endGain: endGain
            )
        } else if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 64 {
            scaleFloat64(
                source: source,
                destination: destination,
                byteCount: byteCount,
                startGain: startGain,
                endGain: endGain
            )
        } else if format.mBitsPerChannel == 16 {
            scaleInt16(
                source: source,
                destination: destination,
                byteCount: byteCount,
                startGain: startGain,
                endGain: endGain
            )
        } else if format.mBitsPerChannel == 32 {
            scaleInt32(
                source: source,
                destination: destination,
                byteCount: byteCount,
                startGain: startGain,
                endGain: endGain
            )
        }

        // The tap can deliver a shorter buffer than the device asked for; the
        // tail would otherwise replay whatever was left in it.
        if byteCount < output.mDataByteSize {
            memset(destination.advanced(by: Int(byteCount)), 0, Int(output.mDataByteSize - byteCount))
        }
    }

    private static func scaleFloat32(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        byteCount: UInt32,
        startGain: Float,
        endGain: Float
    ) {
        let count = vDSP_Length(Int(byteCount) / MemoryLayout<Float>.size)
        guard count > 0 else { return }
        let input = source.assumingMemoryBound(to: Float.self)
        let output = destination.assumingMemoryBound(to: Float.self)

        var value = startGain
        var step = (endGain - startGain) / Float(count)
        vDSP_vrampmul(input, 1, &value, &step, output, 1, count)

        // The limiter attacks within a buffer, so a fast transient can still
        // overshoot slightly on its way down. Clip that rather than let it wrap.
        var low: Float = -1
        var high: Float = 1
        vDSP_vclip(output, 1, &low, &high, output, 1, count)
    }

    private static func scaleFloat64(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        byteCount: UInt32,
        startGain: Float,
        endGain: Float
    ) {
        let count = Int(byteCount) / MemoryLayout<Double>.size
        guard count > 0 else { return }
        let input = source.assumingMemoryBound(to: Double.self)
        let output = destination.assumingMemoryBound(to: Double.self)
        let step = Double(endGain - startGain) / Double(count)

        for index in 0..<count {
            let gain = Double(startGain) + step * Double(index)
            output[index] = min(max(input[index] * gain, -1), 1)
        }
    }

    private static func scaleInt16(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        byteCount: UInt32,
        startGain: Float,
        endGain: Float
    ) {
        let count = Int(byteCount) / MemoryLayout<Int16>.size
        guard count > 0 else { return }
        let input = source.assumingMemoryBound(to: Int16.self)
        let output = destination.assumingMemoryBound(to: Int16.self)
        let step = (endGain - startGain) / Float(count)

        for index in 0..<count {
            let gain = startGain + step * Float(index)
            output[index] = Int16(clamping: Int(Float(input[index]) * gain))
        }
    }

    private static func scaleInt32(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        byteCount: UInt32,
        startGain: Float,
        endGain: Float
    ) {
        let count = Int(byteCount) / MemoryLayout<Int32>.size
        guard count > 0 else { return }
        let input = source.assumingMemoryBound(to: Int32.self)
        let output = destination.assumingMemoryBound(to: Int32.self)
        let step = Double(endGain - startGain) / Double(count)

        for index in 0..<count {
            let gain = Double(startGain) + step * Double(index)
            output[index] = Int32(clamping: Int64(Double(input[index]) * gain))
        }
    }
}

/// Render-thread scratch state. Confined to the IOProc callback, which Core
/// Audio never runs concurrently with itself for one device, so plain stored
/// properties are safe here.
private final class LimiterState: @unchecked Sendable {
    var limiter = PeakLimiter()
    /// The gain the previous buffer finished on, so the next one can ramp from
    /// it instead of stepping.
    var appliedGain: Float = 1
}

private final class RealtimeGain: @unchecked Sendable {
    private let storage: OpaquePointer

    init(initialValue: Float) {
        storage = VMAtomicGainCreate(Self.clamped(initialValue))
    }

    func store(_ value: Float) {
        VMAtomicGainStore(storage, Self.clamped(value))
    }

    func storeMax(_ value: Float) {
        VMAtomicGainStoreMax(storage, Self.clamped(value))
    }

    func exchange(_ newValue: Float) -> Float {
        VMAtomicGainExchange(storage, Self.clamped(newValue))
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
