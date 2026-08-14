import AppKit
import CoreAudio
import Foundation

enum AudioHardware {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func activeSessions(excluding currentPID: Int32) -> [MixerSession] {
        let processIDs = audioObjectIDs(
            objectID: systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )

        var grouped: [String: (name: String, objects: [UInt32], pids: [Int32])] = [:]

        for processObjectID in processIDs {
            guard boolProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ),
            let processID = int32Property(
                objectID: processObjectID,
                selector: kAudioProcessPropertyPID
            ),
            processID != currentPID else {
                continue
            }

            let application = NSRunningApplication(processIdentifier: pid_t(processID))
            let bundleID = stringProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyBundleID
            ) ?? application?.bundleIdentifier

            guard let bundleID, bundleID != Bundle.main.bundleIdentifier else {
                continue
            }

            let displayName = application?.localizedName ?? bundleID
            var entry = grouped[bundleID] ?? (displayName, [], [])
            entry.objects.append(processObjectID)
            entry.pids.append(processID)
            grouped[bundleID] = entry
        }

        return grouped
            .map { bundleID, entry in
                MixerSession(
                    bundleID: bundleID,
                    displayName: entry.name,
                    processObjectIDs: entry.objects.sorted(),
                    processIDs: entry.pids.sorted(),
                    isOutputRunning: true
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
