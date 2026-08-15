import AppKit
import CoreAudio
import Foundation

enum AudioHardware {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Returns every Core Audio process object, including processes that are not
    /// currently playing. `AudioHardwareObserver` uses this to subscribe before
    /// a process starts its next audio stream.
    static func processObjectIDs() -> [AudioObjectID] {
        audioObjectIDs(
            objectID: systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )
    }

    /// Every app Core Audio knows about, grouped by canonical bundle ID, with
    /// **all** of that app's process objects — not only the ones producing audio
    /// right now.
    ///
    /// A tap has to cover the whole app. Building one from just the currently
    /// playing helpers made Chromium and Electron apps rebuild their tap every
    /// time a tab started or stopped audio, which is audible as a dropout, and
    /// it left no route in place for an app that was about to start playing.
    @MainActor
    static func appSessions(excluding currentPID: Int32) -> [MixerSession] {
        var grouped: [String: (
            name: String,
            objects: [UInt32],
            pids: [Int32],
            isRunning: Bool,
            isCapturing: Bool
        )] = [:]

        for processObjectID in processObjectIDs() {
            guard let processID = int32Property(
                objectID: processObjectID,
                selector: kAudioProcessPropertyPID
            ), processID != currentPID else {
                continue
            }

            let rawBundleID = stringProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyBundleID
            )

            // Some processes report no bundle ID, or an empty one. Accepting it
            // produced a nameless row and persisted a junk "" preference.
            guard let identity = identity(rawBundleID: rawBundleID, processID: processID) else {
                continue
            }
            guard identity.bundleID != Bundle.main.bundleIdentifier else { continue }

            let isRunning = boolProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningOutput
            )
            let isCapturing = boolProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningInput
            )

            var entry = grouped[identity.bundleID] ?? (identity.displayName, [], [], false, false)
            entry.objects.append(processObjectID)
            entry.pids.append(processID)
            entry.isRunning = entry.isRunning || isRunning
            entry.isCapturing = entry.isCapturing || isCapturing
            grouped[identity.bundleID] = entry
        }

        return grouped
            .map { bundleID, entry in
                MixerSession(
                    bundleID: bundleID,
                    displayName: entry.name,
                    processObjectIDs: entry.objects.sorted(),
                    processIDs: entry.pids.sorted(),
                    isOutputRunning: entry.isRunning,
                    isInputRunning: entry.isCapturing
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Resolving a bundle ID and a display name means a Launch Services lookup,
    /// which is far too expensive to repeat for every process on every scan.
    @MainActor
    private static var identityCache: [String: (bundleID: String, displayName: String)] = [:]

    @MainActor
    private static func identity(
        rawBundleID: String?,
        processID: Int32
    ) -> (bundleID: String, displayName: String)? {
        if let rawBundleID, let cached = identityCache[rawBundleID] {
            return cached
        }

        let application = NSRunningApplication(processIdentifier: pid_t(processID))
        guard let resolvedRawBundleID = rawBundleID ?? application?.bundleIdentifier,
              !resolvedRawBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let identity = (
            bundleID: ProcessAppIdentity.canonicalBundleID(
                rawBundleID: resolvedRawBundleID,
                bundleURL: application?.bundleURL
            ),
            displayName: ProcessAppIdentity.displayName(
                rawBundleID: resolvedRawBundleID,
                application: application
            )
        )
        identityCache[resolvedRawBundleID] = identity
        return identity
    }

    static func outputDevices() -> [AudioOutputDevice] {
        let defaultDeviceID = defaultOutputDeviceID()
        return audioObjectIDs(objectID: systemObject, selector: kAudioHardwarePropertyDevices)
            .compactMap { deviceID in
                guard hasOutputStreams(deviceID),
                      let uid = stringProperty(
                        objectID: deviceID,
                        selector: kAudioDevicePropertyDeviceUID
                      ),
                      let name = stringProperty(objectID: deviceID, selector: kAudioObjectPropertyName) else {
                    return nil
                }

                return AudioOutputDevice(
                    id: uid,
                    name: name,
                    isDefault: deviceID == defaultDeviceID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func defaultOutputUID() -> String? {
        guard let defaultDeviceID = defaultOutputDeviceID() else { return nil }
        return stringProperty(objectID: defaultDeviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func inactiveSession(forFavorite bundleID: String) -> MixerSession {
        let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let displayName = applicationURL.map {
            FileManager.default.displayName(atPath: $0.path)
        } ?? bundleID

        return MixerSession(
            bundleID: bundleID,
            displayName: displayName,
            processObjectIDs: [],
            processIDs: [],
            isOutputRunning: false
        )
    }

    static func outputChannelCount(deviceUID: String) -> Int? {
        guard let deviceID = deviceID(forUID: deviceUID) else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else {
            return nil
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(dataSize))

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            storage
        ) == noErr else {
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func tapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &dataSize,
            &format
        ) == noErr else {
            return nil
        }
        return format
    }

    static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        }
        return status == noErr ? value as String? : nil
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var output = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &dataSize,
            &output
        ) == noErr, output != kAudioObjectUnknown else {
            return nil
        }
        return output
    }

    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        audioObjectIDs(objectID: systemObject, selector: kAudioHardwarePropertyDevices)
            .first { stringProperty(objectID: $0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr
            && dataSize >= MemoryLayout<AudioObjectID>.size
    }

    private static func audioObjectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioObjectID>.size else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var values = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return values.filter { $0 != kAudioObjectUnknown }
    }

    private static func boolProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr && value != 0
    }

    private static func int32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Int32? {
        var value: Int32 = 0
        var dataSize = UInt32(MemoryLayout<Int32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }
}
