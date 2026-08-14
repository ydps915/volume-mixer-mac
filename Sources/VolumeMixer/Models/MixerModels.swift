import Foundation

struct AppVolumePreference: Codable, Equatable, Sendable {
    var volume: Double
    var isMuted: Bool

    init(volume: Double = 1, isMuted: Bool = false) {
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
    }

    func effectiveGain(masterVolume: Double) -> Float {
        guard !isMuted else { return 0 }
        return Float(min(max(volume * masterVolume, 0), 1))
    }
}

struct MixerAppSettings: Codable, Equatable, Sendable {
    var masterVolume: Double
    var preferredOutputUID: String?
    var mixerEnabled: Bool
    var launchAtLogin: Bool

    init(
        masterVolume: Double = 1,
        preferredOutputUID: String? = nil,
        mixerEnabled: Bool = false,
        launchAtLogin: Bool = false
    ) {
        self.masterVolume = min(max(masterVolume, 0), 1)
        self.preferredOutputUID = preferredOutputUID
        self.mixerEnabled = mixerEnabled
        self.launchAtLogin = launchAtLogin
    }
}

struct MixerSession: Identifiable, Equatable, Sendable {
    let bundleID: String
    let displayName: String
    let processObjectIDs: [UInt32]
    let processIDs: [Int32]
    let isOutputRunning: Bool

    var id: String { bundleID }
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
    let processObjectIDs: [UInt32]
    let gain: Float
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
