import AppKit
import Combine
import Foundation

@MainActor
final class MixerStore: ObservableObject {
    @Published private(set) var sessions: [MixerSession] = []
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var settings: MixerAppSettings
    @Published private(set) var engineState: MixerEngineState = .inactive
    @Published private(set) var systemAudioPermission: SystemAudioPermissionState = .unknown
    @Published private(set) var fallbackMessage: String?
    @Published private(set) var loginItemError: String?

    private let repository: MixerPreferencesRepository
    private let engine: AudioTapEngine
    private var appPreferences: [String: AppVolumePreference]
    private var favoriteBundleIDs: Set<String>
    private var refreshTimer: Timer?
    private var hasStarted = false

    init(
        repository: MixerPreferencesRepository = MixerPreferencesRepository(),
        engine: AudioTapEngine = AudioTapEngine()
    ) {
        self.repository = repository
        self.settings = repository.loadSettings()
        self.appPreferences = repository.loadAppPreferences()
        self.favoriteBundleIDs = repository.loadFavoriteBundleIDs()
        self.engine = engine
        self.engineState = engine.state
        engine.onStateChange = { [weak self] state in
            self?.engineState = state
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        if settings.mixerEnabled {
            setMixerEnabled(true)
        }
    }

    func refresh() {
        outputDevices = AudioHardware.outputDevices()
        let activeSessions = AudioHardware.activeSessions(
            excluding: Int32(ProcessInfo.processInfo.processIdentifier)
        )
        sessions = mergedSessions(with: activeSessions)
        resolveOutputFallback()
        reconcileAudioRoutes()
    }

    func setMixerEnabled(_ enabled: Bool) {
        settings.mixerEnabled = enabled
        saveSettings()

        guard enabled else {
            engine.stop()
            return
        }

        systemAudioPermission = .checking
        engine.activate { [weak self] granted in
            guard let self else { return }
            self.systemAudioPermission = granted ? .granted : .required
            guard granted else {
                self.settings.mixerEnabled = false
                self.saveSettings()
                return
            }
            self.reconcileAudioRoutes()
        }
    }

    func checkSystemAudioPermission() {
        systemAudioPermission = .checking
        engine.checkSystemAudioPermission { [weak self] granted in
            self?.systemAudioPermission = granted ? .granted : .required
        }
    }

    func setMasterVolume(_ volume: Double) {
        settings.masterVolume = min(max(volume, 0), 1)
        saveSettings()
        reconcileAudioRoutes()
    }

    func setPreferredOutput(uid: String?) {
        settings.preferredOutputUID = uid
        saveSettings()
        resolveOutputFallback()
        reconcileAudioRoutes()
    }

    func setVolume(_ volume: Double, for bundleID: String) {
        var preference = appPreferences[bundleID] ?? AppVolumePreference()
        preference.volume = min(max(volume, 0), 1)
        appPreferences[bundleID] = preference
        saveAppPreferences()
        reconcileAudioRoutes()
    }

    func setMuted(_ isMuted: Bool, for bundleID: String) {
        var preference = appPreferences[bundleID] ?? AppVolumePreference()
        preference.isMuted = isMuted
        appPreferences[bundleID] = preference
        saveAppPreferences()
        reconcileAudioRoutes()
    }

    func preference(for bundleID: String) -> AppVolumePreference {
        appPreferences[bundleID] ?? AppVolumePreference()
    }

    func isFavorite(_ bundleID: String) -> Bool {
        favoriteBundleIDs.contains(bundleID)
    }

    func setFavorite(_ isFavorite: Bool, for bundleID: String) {
        if isFavorite {
            favoriteBundleIDs.insert(bundleID)
        } else {
            favoriteBundleIDs.remove(bundleID)
        }
        repository.save(favoriteBundleIDs: favoriteBundleIDs)
        refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            try LoginItemService.setEnabled(enabled)
            settings.launchAtLogin = enabled
            saveSettings()
        } catch {
            loginItemError = "Não foi possível atualizar o item de login: \(error.localizedDescription)"
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    var resolvedOutputUID: String? {
        OutputRouteResolver.resolvedOutputUID(
            preferredUID: settings.preferredOutputUID,
            availableUIDs: Set(outputDevices.map(\.id)),
            defaultUID: outputDevices.first(where: \.isDefault)?.id
        ).uid
    }

    private func resolveOutputFallback() {
        let result = OutputRouteResolver.resolvedOutputUID(
            preferredUID: settings.preferredOutputUID,
            availableUIDs: Set(outputDevices.map(\.id)),
            defaultUID: outputDevices.first(where: \.isDefault)?.id
        )
        fallbackMessage = result.usingFallback
            ? "A saída selecionada não está disponível. O mixer está usando a saída padrão do macOS."
            : nil
    }

    private func reconcileAudioRoutes() {
        let targets = sessions.map { session in
            RouteTarget(
                id: session.bundleID,
                processObjectIDs: session.processObjectIDs,
                gain: preference(for: session.bundleID).effectiveGain(masterVolume: settings.masterVolume)
            )
        }
        engine.reconcile(targets: targets, outputDeviceUID: resolvedOutputUID)
    }

    private func mergedSessions(with activeSessions: [MixerSession]) -> [MixerSession] {
        let activeBundleIDs = Set(activeSessions.map(\.bundleID))
        let inactiveFavorites = favoriteBundleIDs
            .subtracting(activeBundleIDs)
            .map(AudioHardware.inactiveSession(forFavorite:))

        return (activeSessions + inactiveFavorites).sorted { lhs, rhs in
            let lhsIsFavorite = isFavorite(lhs.bundleID)
            let rhsIsFavorite = isFavorite(rhs.bundleID)
            if lhsIsFavorite != rhsIsFavorite { return lhsIsFavorite }
            if lhs.isOutputRunning != rhs.isOutputRunning { return lhs.isOutputRunning }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func saveSettings() {
        repository.save(settings: settings)
    }

    private func saveAppPreferences() {
        repository.save(appPreferences: appPreferences)
    }
}
