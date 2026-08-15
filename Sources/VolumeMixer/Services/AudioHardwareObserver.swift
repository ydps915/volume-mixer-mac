import CoreAudio
import Foundation

/// Receives Core Audio change notifications instead of waiting for the next
/// periodic session scan. In particular, it subscribes to every process's
/// `kAudioProcessPropertyIsRunningOutput` property while that process exists.
///
/// Registration deliberately uses the C function-pointer API rather than
/// `AudioObjectAddPropertyListenerBlock`. Swift re-bridges a stored closure into
/// a **new** Objective-C block every time it is passed to C, so the block handed
/// to the remove call never matched the one that was registered: removal always
/// silently failed and listeners accumulated for the life of the process. As
/// Core Audio recycled process object IDs, duplicate listeners stacked up on the
/// same object and every change fired the handler many times over.
@MainActor
final class AudioHardwareObserver {
    private var observedProcessObjectIDs = Set<AudioObjectID>()
    private var isStarted = false
    /// Retained for as long as listeners are registered, so a callback already
    /// in flight can never resolve a freed observer.
    private var context: UnsafeMutableRawPointer?

    var onChange: (() -> Void)?

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Output tells the mixer an app needs a route. Input tells it an app is in
    /// a call or sharing its screen, which is when Discord has to be left alone.
    private static let processSelectors: [AudioObjectPropertySelector] = [
        kAudioProcessPropertyIsRunningOutput,
        kAudioProcessPropertyIsRunningInput,
    ]

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static let listenerProc: AudioObjectPropertyListenerProc = {
        _, addressCount, addresses, clientData in
        guard let clientData else { return noErr }

        // Only the process list can change which objects are worth observing.
        // Re-enumerating on every notification made a burst of events rescan
        // Core Audio many times over on the main thread.
        var touchesProcessList = false
        for index in 0..<Int(addressCount)
        where addresses[index].mSelector == kAudioHardwarePropertyProcessObjectList {
            touchesProcessList = true
        }

        let refreshProcessListeners = touchesProcessList
        // The raw pointer itself is not `Sendable`; its bit pattern is.
        let contextBits = UInt(bitPattern: clientData)
        Task { @MainActor in
            guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
            let observer = Unmanaged<AudioHardwareObserver>
                .fromOpaque(context)
                .takeUnretainedValue()
            observer.handleChange(refreshingProcessListeners: refreshProcessListeners)
        }
        return noErr
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        context = Unmanaged.passRetained(self).toOpaque()

        addListener(for: Self.systemObject, selector: kAudioHardwarePropertyProcessObjectList)
        addListener(for: Self.systemObject, selector: kAudioHardwarePropertyDevices)
        addListener(for: Self.systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice)
        refreshProcessListeners()
    }

    func stop() {
        guard isStarted, let context else { return }
        isStarted = false

        removeListener(for: Self.systemObject, selector: kAudioHardwarePropertyProcessObjectList)
        removeListener(for: Self.systemObject, selector: kAudioHardwarePropertyDevices)
        removeListener(for: Self.systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice)
        for processObjectID in observedProcessObjectIDs {
            for selector in Self.processSelectors {
                removeListener(for: processObjectID, selector: selector)
            }
        }
        observedProcessObjectIDs.removeAll()

        self.context = nil
        Unmanaged<AudioHardwareObserver>.fromOpaque(context).release()
    }

    private func handleChange(refreshingProcessListeners: Bool) {
        guard isStarted else { return }
        if refreshingProcessListeners {
            refreshProcessListeners()
        }
        onChange?()
    }

    private func refreshProcessListeners() {
        let currentProcessObjectIDs = Set(AudioHardware.processObjectIDs())
        guard currentProcessObjectIDs != observedProcessObjectIDs else { return }

        for processObjectID in observedProcessObjectIDs.subtracting(currentProcessObjectIDs) {
            for selector in Self.processSelectors {
                removeListener(for: processObjectID, selector: selector)
            }
            observedProcessObjectIDs.remove(processObjectID)
        }

        // A process object can die between the enumeration and the add. Only
        // record the ones actually registered, otherwise the observer believes
        // it is watching a process it is not — and later tries to remove a
        // listener that was never installed.
        for processObjectID in currentProcessObjectIDs.subtracting(observedProcessObjectIDs) {
            var registered = false
            for selector in Self.processSelectors {
                registered = addListener(for: processObjectID, selector: selector) || registered
            }
            if registered {
                observedProcessObjectIDs.insert(processObjectID)
            }
        }
    }

    @discardableResult
    private func addListener(
        for objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        guard let context else { return false }
        var address = Self.address(selector)
        let status = AudioObjectAddPropertyListener(objectID, &address, Self.listenerProc, context)
        guard status == noErr else {
            AppLogger.audio.error(
                "Listener add failed for \(objectID, privacy: .public): \(status, privacy: .public)"
            )
            return false
        }
        return true
    }

    private func removeListener(
        for objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) {
        guard let context else { return }
        var address = Self.address(selector)
        let status = AudioObjectRemovePropertyListener(objectID, &address, Self.listenerProc, context)
        guard status != noErr else { return }

        // A process object that has already gone away is the normal way a
        // per-process listener ends; there is nothing left to detach.
        if status == kAudioHardwareBadObjectError {
            AppLogger.audio.debug("Listener target \(objectID, privacy: .public) already gone")
        } else {
            AppLogger.audio.error(
                "Listener remove failed for \(objectID, privacy: .public): \(status, privacy: .public)"
            )
        }
    }
}
