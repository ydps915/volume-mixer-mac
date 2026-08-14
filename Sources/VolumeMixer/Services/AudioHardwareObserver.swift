import CoreAudio
import Foundation

/// Receives Core Audio change notifications instead of waiting for the next
/// periodic session scan. In particular, it subscribes to every process's
/// `kAudioProcessPropertyIsRunningOutput` property while that process exists.
///
/// The listener blocks execute on `callbackQueue`; all state changes and the
/// client callback are then dispatched to the main actor. This keeps Core Audio
/// callbacks short and avoids changing SwiftUI state from an audio callback.
@MainActor
final class AudioHardwareObserver {
    private let callbackQueue = DispatchQueue(
        label: "com.ydps915.VolumeMixer.audio-hardware-observer",
        qos: .userInitiated
    )
    private var observedProcessObjectIDs = Set<AudioObjectID>()
    private var isStarted = false

    var onChange: (() -> Void)?

    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            self?.didReceiveAudioHardwareChange()
        }
    }

    private let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let outputDeviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let processOutputRunningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        guard !isStarted else { return }
        isStarted = true

        addListener(for: AudioObjectID(kAudioObjectSystemObject), address: processListAddress)
        addListener(for: AudioObjectID(kAudioObjectSystemObject), address: outputDeviceListAddress)
        addListener(for: AudioObjectID(kAudioObjectSystemObject), address: defaultOutputAddress)
        refreshProcessListeners()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        removeListener(for: AudioObjectID(kAudioObjectSystemObject), address: processListAddress)
        removeListener(for: AudioObjectID(kAudioObjectSystemObject), address: outputDeviceListAddress)
        removeListener(for: AudioObjectID(kAudioObjectSystemObject), address: defaultOutputAddress)
        for processObjectID in observedProcessObjectIDs {
            removeListener(for: processObjectID, address: processOutputRunningAddress)
        }
        observedProcessObjectIDs.removeAll()
    }

    private func didReceiveAudioHardwareChange() {
        guard isStarted else { return }
        refreshProcessListeners()
        onChange?()
    }

    private func refreshProcessListeners() {
        let currentProcessObjectIDs = Set(AudioHardware.processObjectIDs())
        let removed = observedProcessObjectIDs.subtracting(currentProcessObjectIDs)
        let added = currentProcessObjectIDs.subtracting(observedProcessObjectIDs)

        for processObjectID in removed {
            removeListener(for: processObjectID, address: processOutputRunningAddress)
        }
        for processObjectID in added {
            addListener(for: processObjectID, address: processOutputRunningAddress)
        }
        observedProcessObjectIDs = currentProcessObjectIDs
    }

    private func addListener(
        for objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) {
        var address = address
        _ = AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            callbackQueue,
            listener
        )
    }

    private func removeListener(
        for objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) {
        var address = address
        _ = AudioObjectRemovePropertyListenerBlock(
            objectID,
            &address,
            callbackQueue,
            listener
        )
    }
}
