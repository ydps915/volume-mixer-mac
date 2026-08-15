import Foundation

struct AppVolumePreference: Codable, Equatable, Sendable {
    var volume: Double
    var isMuted: Bool
    var boostEnabled: Bool

    init(volume: Double = 1, isMuted: Bool = false, boostEnabled: Bool = false) {
        self.boostEnabled = boostEnabled
        // Kept up to 200% even with boost off, so turning boost off and on again
        // restores the level the user had set instead of silently losing it.
        self.volume = min(max(volume, 0), 2)
        self.isMuted = isMuted
    }

    var maximumVolume: Double { boostEnabled ? 2 : 1 }

    /// The volume actually in force, which is capped at 100% while boost is off.
    var appliedVolume: Double { min(volume, maximumVolume) }

    func effectiveGain(masterVolume: Double) -> Float {
        guard !isMuted else { return 0 }
        return Float(min(max(appliedVolume * masterVolume, 0), maximumVolume))
    }

    private enum CodingKeys: String, CodingKey {
        case volume
        case isMuted
        case boostEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1,
            isMuted: try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            boostEnabled: try container.decodeIfPresent(Bool.self, forKey: .boostEnabled) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(volume, forKey: .volume)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(boostEnabled, forKey: .boostEnabled)
    }
}

struct MixerAppSettings: Codable, Equatable, Sendable {
    var masterVolume: Double
    var preferredOutputUID: String?
    var mixerEnabled: Bool
    var launchAtLogin: Bool
    var discordProtection: DiscordProtectionMode

    init(
        masterVolume: Double = 1,
        preferredOutputUID: String? = nil,
        mixerEnabled: Bool = false,
        launchAtLogin: Bool = false,
        discordProtection: DiscordProtectionMode = .duringCallsAndStreams
    ) {
        self.masterVolume = min(max(masterVolume, 0), 1)
        self.preferredOutputUID = preferredOutputUID
        self.mixerEnabled = mixerEnabled
        self.launchAtLogin = launchAtLogin
        self.discordProtection = discordProtection
    }

    private enum CodingKeys: String, CodingKey {
        case masterVolume
        case preferredOutputUID
        case mixerEnabled
        case launchAtLogin
        case discordProtection
        case protectDiscordDuringStreams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            masterVolume: try container.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 1,
            preferredOutputUID: try container.decodeIfPresent(String.self, forKey: .preferredOutputUID),
            mixerEnabled: try container.decodeIfPresent(Bool.self, forKey: .mixerEnabled) ?? false,
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
            discordProtection: try Self.decodeProtection(from: container)
        )
    }

    /// The setting used to be a Bool. `true` meant "never route Discord", which
    /// maps to `.always`. `false` left the user exposed to the screen-share echo
    /// this protection exists for, so it now becomes the automatic mode rather
    /// than `.never`.
    private static func decodeProtection(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> DiscordProtectionMode {
        if let mode = try container.decodeIfPresent(
            DiscordProtectionMode.self,
            forKey: .discordProtection
        ) {
            return mode
        }
        let legacyAlwaysProtect = try container.decodeIfPresent(
            Bool.self,
            forKey: .protectDiscordDuringStreams
        )
        return legacyAlwaysProtect == true ? .always : .duringCallsAndStreams
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(masterVolume, forKey: .masterVolume)
        try container.encodeIfPresent(preferredOutputUID, forKey: .preferredOutputUID)
        try container.encode(mixerEnabled, forKey: .mixerEnabled)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(discordProtection, forKey: .discordProtection)
    }
}

struct MixerSession: Identifiable, Equatable, Sendable {
    let bundleID: String
    let displayName: String
    let processObjectIDs: [UInt32]
    let processIDs: [Int32]
    let isOutputRunning: Bool
    /// The app is capturing audio — a call, a recording, or a screen share with
    /// sound. See `StreamSafetyPolicy`.
    let isInputRunning: Bool

    var id: String { bundleID }

    init(
        bundleID: String,
        displayName: String,
        processObjectIDs: [UInt32],
        processIDs: [Int32],
        isOutputRunning: Bool,
        isInputRunning: Bool = false
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.processObjectIDs = processObjectIDs
        self.processIDs = processIDs
        self.isOutputRunning = isOutputRunning
        self.isInputRunning = isInputRunning
    }
}

struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}

enum MixerEngineState: Equatable, Sendable {
    case inactive
    case requestingPermission
    case active
    case permissionRequired
    case unsupported
    case failed(String)

    var message: String? {
        switch self {
        case .inactive:
            return nil
        case .requestingPermission:
            return "Aguardando a permissão de captura de áudio do sistema."
        case .active:
            return "Mixer ativo"
        case .permissionRequired:
            return "Permita a captura de áudio do sistema em Ajustes do Sistema para habilitar o mixer."
        case .unsupported:
            return "O Volume Mixer requer macOS 14.2 ou posterior."
        case .failed(let error):
            return error
        }
    }
}

enum SystemAudioPermissionState: Equatable, Sendable {
    case unknown
    case checking
    case granted
    case required

    var title: String {
        switch self {
        case .unknown: "Não verificada"
        case .checking: "Verificando"
        case .granted: "Ativa"
        case .required: "Necessária"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            "Verifique se o macOS já autorizou a captura de áudio do sistema."
        case .checking:
            "O macOS está verificando o acesso à captura de áudio."
        case .granted:
            "O Volume Mixer pode processar o áudio do sistema localmente."
        case .required:
            "Permita o Volume Mixer nos Ajustes do Sistema para ativar o mixer."
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .checking: "hourglass"
        case .granted: "checkmark.shield.fill"
        case .required: "exclamationmark.shield.fill"
        }
    }
}

struct RouteTarget: Equatable, Sendable {
    let id: String
    let displayName: String
    let processObjectIDs: [UInt32]
    let gain: Float
}

/// Keeps an app's route alive for a short time after it goes silent, so a
/// player that is paused and resumed does not have to rebuild its tap — which
/// is slow enough to briefly leak unmodified audio to the regular output.
///
/// Only bundle IDs are remembered. An earlier version cached the whole session,
/// including its Core Audio process object IDs; those IDs get recycled, so a
/// stale entry could build a tap over whatever process inherited the number.
/// The caller now always pairs a remembered bundle ID with a freshly scanned
/// process set.
struct WarmRouteCache {
    private let retention: TimeInterval
    private var lastActiveAt: [String: Date] = [:]

    init(retention: TimeInterval) {
        self.retention = max(retention, 0)
    }

    mutating func update(
        activeBundleIDs: Set<String>,
        now: Date = .now
    ) -> Set<String> {
        for bundleID in activeBundleIDs {
            lastActiveAt[bundleID] = now
        }
        lastActiveAt = lastActiveAt.filter { now.timeIntervalSince($0.value) <= retention }
        return Set(lastActiveAt.keys)
    }
}

enum DiscordProtectionMode: String, Codable, CaseIterable, Sendable {
    /// Leave Discord out of the mixer only while it is capturing audio, which is
    /// what a call or a screen share with sound looks like from Core Audio.
    case duringCallsAndStreams
    /// Never route Discord through the mixer.
    case always
    /// Always route it; the user accepts the echo risk while sharing.
    case never

    var title: String {
        switch self {
        case .duringCallsAndStreams: "Durante chamadas e streams"
        case .always: "Sempre"
        case .never: "Nunca"
        }
    }
}

/// Why this exists: to change an app's volume the mixer has to mute that app and
/// re-render its audio, which makes **Volume Mixer** the process emitting the
/// sound. Discord's screen share captures every process except its own, so it
/// cannot exclude that re-rendered copy — participants end up hearing
/// themselves. There is no way to opt out of another app's capture, so the only
/// fix is to leave Discord on its own route while it is capturing.
enum StreamSafetyPolicy {
    static func isStreamSensitive(bundleID: String) -> Bool {
        let normalizedBundleID = bundleID.lowercased()
        return normalizedBundleID.hasPrefix("com.hnc.discord")
            || normalizedBundleID.hasPrefix("com.discord.discord")
            || normalizedBundleID.hasPrefix("com.discordapp.discord")
    }

    static func excludesFromMixerCapture(
        bundleID: String,
        mode: DiscordProtectionMode,
        isCapturingAudio: Bool
    ) -> Bool {
        guard isStreamSensitive(bundleID: bundleID) else { return false }
        switch mode {
        case .always: return true
        case .never: return false
        case .duringCallsAndStreams: return isCapturingAudio
        }
    }
}

enum OutputRouteResolver {
    static func resolvedOutputUID(
        preferredUID: String?,
        availableUIDs: Set<String>,
        defaultUID: String?
    ) -> (uid: String?, usingFallback: Bool) {
        guard let preferredUID else {
            return (defaultUID, false)
        }
        if availableUIDs.contains(preferredUID) {
            return (preferredUID, false)
        }
        return (defaultUID, true)
    }
}

enum MixerActivationPolicy {
    static func canActivate(
        osVersion: OperatingSystemVersion,
        permissionGranted: Bool
    ) -> Bool {
        let isSupported = osVersion.majorVersion > 14
            || (osVersion.majorVersion == 14 && osVersion.minorVersion >= 2)
        return isSupported && permissionGranted
    }
}
