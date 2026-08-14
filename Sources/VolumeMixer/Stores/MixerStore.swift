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
    @Published private(set) var appLevels: [String: Double] = [:]
    @Published private(set) var fallbackMessage: String?
    @Published private(set) var routingIssue: String?
    @Published private(set) var loginItemError: String?

    private let repository: MixerPreferencesRepository
    private let engine: AudioTapEngine
    private var appPreferences: [String: AppVolumePreference]
    private var favoriteBundleIDs: Set<String>
    private var warmRouteCache = WarmRouteCache(retention: 20)
    private var warmRouteSessions: [MixerSession] = []
    private var refreshTimer: Timer?
    private var eventRefreshPending = false
    private var hasStarted = false

    private lazy var hardwareObserver: AudioHardwareObserver = {
        let observer = AudioHardwareObserver()
        observer.onChange = { [weak self] in
            self?.scheduleEventRefresh()
        }
        return observer
    }()

    init(
        repository: MixerPreferencesRepository = MixerPreferencesRepository(),
        engine: AudioTapEngine = AudioTapEngine()
    ) {
        self.repository = repository
        self.settings = repository.loadSettings()
        let loadedAppPreferences = repository.loadAppPreferences()
        let loadedFavoriteBundleIDs = repository.loadFavoriteBundleIDs()
        self.appPreferences = Self.canonicalizedAppPreferences(loadedAppPreferences)
        self.favoriteBundleIDs = Self.canonicalizedBundleIDs(loadedFavoriteBundleIDs)
        self.engine = engine
        self.engineState = engine.state

        if self.appPreferences != loadedAppPreferences {
            repository.save(appPreferences: self.appPreferences)
        }
        if self.favoriteBundleIDs != loadedFavoriteBundleIDs {
            repository.save(favoriteBundleIDs: self.favoriteBundleIDs)
        }
        engine.onStateChange = { [weak self] state in
            self?.engineState = state
        }
        engine.onLevelsChange = { [weak self] levels in
            self?.appLevels = levels.mapValues(Double.init)
        }
        engine.onRoutingIssueChange = { [weak self] issue in
            self?.routingIssue = issue
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        hardwareObserver.start()
        refresh()
        // Core Audio listeners perform the immediate refresh. This is only a
        // recovery scan for a third-party device/process that misses an event.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
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
        warmRouteSessions = warmRouteCache.update(activeSessions: activeSessions)
        sessions = mergedSessions(with: activeSessions)
        resolveOutputFallback()
        reconcileAudioRoutes()
    }

    func setMixerEnabled(_ enabled: Bool) {
        settings.mixerEnabled = enabled
        saveSettings()

        guard enabled else {
            engine.stop()
            appLevels = [:]
            routingIssue = nil
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
        preference.volume = min(max(volume, 0), preference.maximumVolume)
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

    func level(for bundleID: String) -> Double {
        appLevels[bundleID] ?? 0
    }

    func setBoostEnabled(_ enabled: Bool, for bundleID: String) {
        var preference = appPreferences[bundleID] ?? AppVolumePreference()
        preference.boostEnabled = enabled
        preference.volume = min(preference.volume, preference.maximumVolume)
        appPreferences[bundleID] = preference
        saveAppPreferences()
        reconcileAudioRoutes()
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

    func setDiscordStreamProtection(_ enabled: Bool) {
        settings.protectDiscordDuringStreams = enabled
        saveSettings()
        reconcileAudioRoutes()
    }

    func isProtectedFromMixerCapture(_ bundleID: String) -> Bool {
        settings.protectDiscordDuringStreams
            && StreamSafetyPolicy.excludesFromMixerCapture(bundleID: bundleID)
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
        let protectedBundleIDs = Set(
            warmRouteSessions
                .filter { isProtectedFromMixerCapture($0.bundleID) }
                .map(\.bundleID)
        )
        if !protectedBundleIDs.isEmpty {
            appLevels = appLevels.filter { !protectedBundleIDs.contains($0.key) }
        }

        let targets = warmRouteSessions
            .filter { !isProtectedFromMixerCapture($0.bundleID) }
            .map { session in
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

    private func scheduleEventRefresh() {
        guard hasStarted, !eventRefreshPending else { return }
        eventRefreshPending = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.eventRefreshPending = false
            self.refresh()
        }
    }

    private func saveSettings() {
        repository.save(settings: settings)
    }

    private func saveAppPreferences() {
        repository.save(appPreferences: appPreferences)
    }

    private static func canonicalizedAppPreferences(
        _ preferences: [String: AppVolumePreference]
    ) -> [String: AppVolumePreference] {
        var normalized = preferences
        for (bundleID, preference) in preferences {
            let canonicalBundleID = ProcessAppIdentity.canonicalBundleID(
                rawBundleID: bundleID,
                bundleURL: nil
            )
            guard canonicalBundleID != bundleID else { continue }
            if preferences[canonicalBundleID] == nil {
                normalized[canonicalBundleID] = preference
            }
            normalized.removeValue(forKey: bundleID)
        }
        return normalized
    }

    private static func canonicalizedBundleIDs(_ bundleIDs: Set<String>) -> Set<String> {
        Set(bundleIDs.map {
            ProcessAppIdentity.canonicalBundleID(rawBundleID: $0, bundleURL: nil)
        })
    }
}
