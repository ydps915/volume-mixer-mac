import Foundation

struct AppVolumePreference: Codable, Equatable, Sendable {
    var volume: Double
    var isMuted: Bool
    var boostEnabled: Bool
    /// Keep this app on its own route: the mixer neither meters nor renders it.
    /// The one-click escape from the screen-share echo described in
    /// `StreamSafetyPolicy`.
    var bypassMixer: Bool

    init(
        volume: Double = 1,
        isMuted: Bool = false,
        boostEnabled: Bool = false,
        bypassMixer: Bool = false
    ) {
        self.bypassMixer = bypassMixer
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
        case bypassMixer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1,
            isMuted: try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            boostEnabled: try container.decodeIfPresent(Bool.self, forKey: .boostEnabled) ?? false,
            bypassMixer: try container.decodeIfPresent(Bool.self, forKey: .bypassMixer) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(volume, forKey: .volume)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(boostEnabled, forKey: .boostEnabled)
        try container.encode(bypassMixer, forKey: .bypassMixer)
    }
}

struct MixerAppSettings: Codable, Equatable, Sendable {
    var masterVolume: Double
    var preferredOutputUID: String?
    var mixerEnabled: Bool
    var launchAtLogin: Bool
    /// Off by default: taking Discord out of the mixer mid-call also takes away
    /// the boost used to hear a quiet microphone. The per-app bypass button is
    /// the primary control; this only automates it.
    var autoBypassWhileCapturing: Bool
    /// On by default: boost without it clips as soon as a quiet talker raises
    /// their voice, which is the main reason boost sounds bad. See `PeakLimiter`.
    var limitPeaksWhenBoosting: Bool

    init(
        masterVolume: Double = 1,
        preferredOutputUID: String? = nil,
        mixerEnabled: Bool = false,
        launchAtLogin: Bool = false,
        autoBypassWhileCapturing: Bool = false,
        limitPeaksWhenBoosting: Bool = true
    ) {
        self.masterVolume = min(max(masterVolume, 0), 1)
        self.preferredOutputUID = preferredOutputUID
        self.mixerEnabled = mixerEnabled
        self.launchAtLogin = launchAtLogin
        self.autoBypassWhileCapturing = autoBypassWhileCapturing
        self.limitPeaksWhenBoosting = limitPeaksWhenBoosting
    }

    private enum CodingKeys: String, CodingKey {
        case masterVolume
        case preferredOutputUID
        case mixerEnabled
        case launchAtLogin
        case autoBypassWhileCapturing
        case limitPeaksWhenBoosting
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Earlier builds stored `protectDiscordDuringStreams` and then
        // `discordProtection`. Both are dropped rather than migrated: they made
        // the choice global and automatic, which is what this replaces.
        self.init(
            masterVolume: try container.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 1,
            preferredOutputUID: try container.decodeIfPresent(String.self, forKey: .preferredOutputUID),
            mixerEnabled: try container.decodeIfPresent(Bool.self, forKey: .mixerEnabled) ?? false,
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
            autoBypassWhileCapturing: try container.decodeIfPresent(
                Bool.self,
                forKey: .autoBypassWhileCapturing
            ) ?? false,
            limitPeaksWhenBoosting: try container.decodeIfPresent(
                Bool.self,
                forKey: .limitPeaksWhenBoosting
            ) ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(masterVolume, forKey: .masterVolume)
        try container.encodeIfPresent(preferredOutputUID, forKey: .preferredOutputUID)
        try container.encode(mixerEnabled, forKey: .mixerEnabled)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(autoBypassWhileCapturing, forKey: .autoBypassWhileCapturing)
        try container.encode(limitPeaksWhenBoosting, forKey: .limitPeaksWhenBoosting)
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
    var limitPeaks: Bool = false
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

/// Why this exists: to change an app's volume the mixer has to mute that app and
/// re-render its audio, which makes **Volume Mixer** the process emitting the
/// sound. A screen share captures every process except the sharing app's own, so
/// it cannot exclude that re-rendered copy — participants end up hearing
/// themselves. There is no way to opt out of another app's capture, so the only
/// fix is to leave the app on its own route.
///
/// That is a manual choice by default: silently dropping Discord from the mixer
/// during a call also takes away the boost people rely on to hear a quiet mic.
/// The row shows a warning instead, and one click bypasses the app.
enum StreamSafetyPolicy {
    /// Apps that capture system audio for screen sharing, and therefore echo if
    /// the mixer renders them.
    static func isStreamSensitive(bundleID: String) -> Bool {
        let normalizedBundleID = bundleID.lowercased()
        return normalizedBundleID.hasPrefix("com.hnc.discord")
            || normalizedBundleID.hasPrefix("com.discord.discord")
            || normalizedBundleID.hasPrefix("com.discordapp.discord")
    }

    static func bypassesMixer(
        bundleID: String,
        bypassMixer: Bool,
        autoBypassWhileCapturing: Bool,
        isCapturingAudio: Bool
    ) -> Bool {
        if bypassMixer { return true }
        return autoBypassWhileCapturing
            && isCapturingAudio
            && isStreamSensitive(bundleID: bundleID)
    }

    /// The app is being rendered by the mixer while it is capturing audio, so a
    /// screen share right now would feed its own audio back into the call.
    static func warnsAboutEcho(
        bundleID: String,
        isBypassingMixer: Bool,
        isCapturingAudio: Bool
    ) -> Bool {
        !isBypassingMixer && isCapturingAudio && isStreamSensitive(bundleID: bundleID)
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

/// Keeps a boosted app from clipping.
///
/// Boost is normally used to hear someone with a quiet microphone. The same
/// boost then makes them clip the moment they speak up, which is what the ear
/// hears as crackling. This pulls the gain down only while the signal would
/// exceed the ceiling, so quiet speech keeps the full boost.
///
/// It is a value type with no allocation so the audio render thread can run it.
struct PeakLimiter: Equatable, Sendable {
    /// About -1 dBFS. Leaves headroom for the inter-sample peaks that a hard
    /// 0 dBFS ceiling would let through.
    static let ceiling: Float = 0.891
    /// Slow enough that a sentence does not pump between words.
    static let releaseTime: Float = 0.25

    private(set) var reduction: Float = 1

    /// - Parameters:
    ///   - inputPeak: peak magnitude of the buffer about to be rendered, 0...1.
    ///   - gain: the gain the mixer would otherwise apply.
    ///   - bufferDuration: length of that buffer in seconds.
    /// - Returns: the gain to apply instead.
    mutating func nextGain(
        inputPeak: Float,
        gain: Float,
        bufferDuration: Float
    ) -> Float {
        let projectedPeak = inputPeak * gain
        let requiredReduction = projectedPeak > Self.ceiling
            ? Self.ceiling / projectedPeak
            : 1

        if requiredReduction < reduction {
            // Attack: the peak was measured before rendering, so taking the
            // reduction on this very buffer means the transient never gets out.
            reduction = requiredReduction
        } else {
            // Release: recover gradually, or the level audibly pumps.
            let duration = min(max(bufferDuration, 0.001), 0.1)
            let coefficient = 1 - exp(-duration / Self.releaseTime)
            reduction += (requiredReduction - reduction) * coefficient
        }

        reduction = min(max(reduction, 0), 1)
        return gain * reduction
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
