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
    /// Raised when a route was found dead and torn down, so the store can
    /// reconcile immediately instead of waiting for the next scan.
    var onRoutesNeedRebuild: (@MainActor () -> Void)?

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
        controller.onRoutesNeedRebuild = { [weak self] in
            Task { @MainActor in
                self?.onRoutesNeedRebuild?()
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
    private var lastRenderCounts: [String: UInt64] = [:]
    private var stalledChecks: [String: Int] = [:]
    /// Targets whose app is producing audio right now. A pre-armed route for an
    /// idle app legitimately gets no callbacks, so it must never be judged dead.
    private var playingTargetIDs: Set<String> = []
    private var lastHealthCheckAt = Date.distantPast
    var onLevels: (@Sendable ([String: Float]) -> Void)?
    var onRoutesNeedRebuild: (@Sendable () -> Void)?

    private static let retryCooldown: TimeInterval = 5
    private static let healthCheckInterval: TimeInterval = 1
    /// Three consecutive silent checks. An app that pauses stops producing
    /// callbacks too, and the notification that it stopped can lag the pause by
    /// a moment; this keeps that from being read as a dead route.
    private static let stallTolerance = 3

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
            self.lastRenderCounts.removeAll()
            self.stalledChecks.removeAll()
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

        playingTargetIDs = Set(desired.values.filter(\.isPlaying).map(\.id))

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
        checkRouteHealth()
    }

    /// A mixing route mutes its app at the system level, so when the route stops
    /// rendering the app goes **silent** rather than merely unadjusted. That is
    /// the failure users worked around by toggling the mixer off and on.
    ///
    /// Retiring the route destroys the tap, which unmutes the app immediately;
    /// the rebuild then happens on the next reconcile.
    private func checkRouteHealth() {
        let now = Date()
        guard now.timeIntervalSince(lastHealthCheckAt) >= Self.healthCheckInterval else { return }
        lastHealthCheckAt = now

        var unhealthy: [(id: String, reason: String)] = []
        for (id, route) in routes where route.mode == .mixing {
            // An idle app's tap simply has nothing to deliver.
            guard playingTargetIDs.contains(id) else {
                lastRenderCounts.removeValue(forKey: id)
                stalledChecks.removeValue(forKey: id)
                continue
            }
            // A device that changes format underneath a running route — a
            // Bluetooth headset switching sample rate is the common case —
            // leaves it rendering into the wrong shape, which is heard as
            // distortion rather than silence.
            if let current = AudioHardware.outputStreamFormat(deviceUID: route.outputDeviceUID),
               !Self.isSameFormat(current, route.deviceFormat) {
                unhealthy.append((id, "device format changed"))
                continue
            }

            let renderCount = route.renderCount
            defer { lastRenderCounts[id] = renderCount }
            guard let previous = lastRenderCounts[id] else { continue }

            if renderCount == previous {
                let stalls = (stalledChecks[id] ?? 0) + 1
                stalledChecks[id] = stalls
                if stalls >= Self.stallTolerance {
                    unhealthy.append((id, "stopped rendering"))
                }
            } else {
                stalledChecks[id] = 0
            }
        }

        guard !unhealthy.isEmpty else { return }
        for (id, reason) in unhealthy {
            AppLogger.audio.error(
                "Route \(id, privacy: .public) unhealthy (\(reason, privacy: .public)); rebuilding"
            )
            retireRoute(id: id)
            lastRenderCounts.removeValue(forKey: id)
            stalledChecks.removeValue(forKey: id)
            // Rebuild at once instead of waiting out the failure cooldown.
            retryNotBefore.removeValue(forKey: id)
        }
        onRoutesNeedRebuild?()
    }

    private static func isSameFormat(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mFormatID == rhs.mFormatID
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
    /// Bumped by every render callback so the controller can tell a stalled
    /// route from a working one.
    private let renderCounter = RenderCounter()
    private var renderPlan: RenderPlan?
    private(set) var deviceFormat = AudioStreamBasicDescription()
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
        guard let tapFormat = AudioHardware.tapFormat(tapID: tapID) else {
            AppLogger.audio.error("Tap format unavailable for \(processObjectIDs, privacy: .public)")
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

        // The device's own format, not the tap's. They routinely disagree —
        // 44.1 kHz on a Bluetooth headset against a 48 kHz tap — and rendering
        // one as if it were the other is what made the audio sound filtered.
        let deviceFormat = mode == .mixing
            ? AudioHardware.outputStreamFormat(deviceID: aggregateDeviceID)
            : tapFormat
        guard let deviceFormat,
              let plan = RenderPlan(tapFormat: tapFormat, deviceFormat: deviceFormat) else {
            AppLogger.audio.error(
                """
                Unrenderable pair, declining route so the app keeps playing: \
                tap=\(Self.describe(tapFormat), privacy: .public) \
                device=\(deviceFormat.map(Self.describe) ?? "unknown", privacy: .public)
                """
            )
            stop()
            return nil
        }
        self.renderPlan = plan
        self.deviceFormat = deviceFormat

        AppLogger.audio.notice(
            """
            route tap=\(Self.describe(tapFormat), privacy: .public) \
            device=\(Self.describe(deviceFormat), privacy: .public) \
            mode=\(mode == .mixing ? "mixing" : "monitoring", privacy: .public)
            """
        )

        let sampleRate = deviceFormat.mSampleRate
        let renderCounter = renderCounter
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
                renderCounter.increment()
                Self.render(
                    inputData: inputData,
                    outputData: outputData,
                    plan: plan,
                    sampleRate: sampleRate,
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

    /// Monotonic count of render callbacks. A mixing route whose count stops
    /// advancing is dead: its app is muted at the system level and silent.
    var renderCount: UInt64 { renderCounter.load() }

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

    static func describe(_ format: AudioStreamBasicDescription) -> String {
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        return "\(Int(format.mSampleRate))Hz/\(format.mChannelsPerFrame)ch/"
            + "\(format.mBitsPerChannel)bit/\(format.mBytesPerFrame)bpf/"
            + (interleaved ? "il" : "ni") + (isFloat ? "/f" : "/i")
    }

    private static func render(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        plan: RenderPlan,
        sampleRate: Double,
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

        let peak = peakLevel(inputs: inputs)
        let inputFrames = inputs.first.map {
            plan.inputFrames(byteCountOfFirstBuffer: Int($0.mDataByteSize))
        } ?? 0

        if !limiterState.hasLoggedGeometry {
            limiterState.hasLoggedGeometry = true
            let outputFrames = outputs.first.map {
                plan.outputFrames(byteCountOfFirstBuffer: Int($0.mDataByteSize))
            } ?? 0
            AppLogger.audio.notice(
                """
                geometry inBuffers=\(inputs.count, privacy: .public) \
                inFrames=\(inputFrames, privacy: .public) \
                outBuffers=\(outputs.count, privacy: .public) \
                outFrames=\(outputFrames, privacy: .public)
                """
            )
        }

        var targetGain = gain
        if limitsPeaks {
            let duration = sampleRate > 0 ? Float(inputFrames) / Float(sampleRate) : 0.01
            targetGain = limiterState.limiter.nextGain(
                inputPeak: peak,
                gain: gain,
                bufferDuration: duration
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

        write(
            inputs: inputs,
            outputs: outputs,
            plan: plan,
            inputFrames: inputFrames,
            startGain: startGain,
            endGain: targetGain
        )
    }

    private static func silence(_ buffer: AudioBuffer) {
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
        memset(data, 0, Int(buffer.mDataByteSize))
    }

    private static func peakLevel(inputs: UnsafeMutableAudioBufferListPointer) -> Float {
        var peak: Float = 0
        for buffer in inputs {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let count = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            guard count > 0 else { continue }
            var bufferPeak: Float = 0
            vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, count)
            peak = max(peak, bufferPeak)
        }
        return min(peak, 1)
    }

    /// Copies the tap into the device channel by channel, honouring each side's
    /// own interleaving. Copying buffer-to-buffer with a single format worked
    /// only while the tap and the device happened to agree.
    private static func write(
        inputs: UnsafeMutableAudioBufferListPointer,
        outputs: UnsafeMutableAudioBufferListPointer,
        plan: RenderPlan,
        inputFrames: Int,
        startGain: Float,
        endGain: Float
    ) {
        guard let firstOutput = outputs.first else { return }
        let outputFrames = plan.outputFrames(byteCountOfFirstBuffer: Int(firstOutput.mDataByteSize))
        let frames = min(inputFrames, outputFrames)

        guard frames > 0 else {
            for index in outputs.indices { silence(outputs[index]) }
            return
        }

        var low: Float = -1
        var high: Float = 1

        for outputChannel in 0..<plan.outputChannels {
            let destination = plan.outputLocation(forChannel: outputChannel)
            let source = plan.inputLocation(forChannel: plan.sourceChannel(forOutputChannel: outputChannel))
            guard destination.buffer < outputs.count,
                  source.buffer < inputs.count,
                  let destinationData = outputs[destination.buffer].mData,
                  let sourceData = inputs[source.buffer].mData else {
                continue
            }

            let input = sourceData.assumingMemoryBound(to: Float.self).advanced(by: source.offset)
            let output = destinationData.assumingMemoryBound(to: Float.self)
                .advanced(by: destination.offset)

            var value = startGain
            var step = (endGain - startGain) / Float(frames)
            vDSP_vrampmul(
                input,
                vDSP_Stride(source.stride),
                &value,
                &step,
                output,
                vDSP_Stride(destination.stride),
                vDSP_Length(frames)
            )
            // The limiter attacks within a buffer, so a fast transient can still
            // overshoot slightly on its way down. Clip that rather than let it
            // wrap around.
            vDSP_vclip(
                output,
                vDSP_Stride(destination.stride),
                &low,
                &high,
                output,
                vDSP_Stride(destination.stride),
                vDSP_Length(frames)
            )
        }

        // The tap can deliver fewer frames than the device asked for; the tail
        // would otherwise replay whatever was left in the buffer.
        guard outputFrames > frames else { return }
        for outputChannel in 0..<plan.outputChannels {
            let destination = plan.outputLocation(forChannel: outputChannel)
            guard destination.buffer < outputs.count,
                  let destinationData = outputs[destination.buffer].mData else {
                continue
            }
            let output = destinationData.assumingMemoryBound(to: Float.self)
                .advanced(by: destination.offset)
            for frame in frames..<outputFrames {
                output[frame * destination.stride] = 0
            }
        }
    }
}

/// Render-thread scratch state. Confined to the IOProc callback, which Core
/// Audio never runs concurrently with itself for one device, so plain stored
/// properties are safe here.
private final class LimiterState: @unchecked Sendable {
    var limiter = PeakLimiter()
    /// Diagnostics: the real buffer geometry is logged once per route, because
    /// the tap's declared format is not what the device renders.
    var hasLoggedGeometry = false
    /// The gain the previous buffer finished on, so the next one can ramp from
    /// it instead of stepping.
    var appliedGain: Float = 1
}

private final class RenderCounter: @unchecked Sendable {
    private let storage: OpaquePointer?

    init() {
        storage = VMAtomicCounterCreate()
    }

    func increment() {
        VMAtomicCounterIncrement(storage)
    }

    func load() -> UInt64 {
        VMAtomicCounterLoad(storage)
    }

    deinit {
        VMAtomicCounterDestroy(storage)
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
