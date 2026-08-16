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
    @Published private(set) var routingIssue: String?
    @Published private(set) var loginItemError: String?

    let levels = AudioLevelStore()

    private let repository: MixerPreferencesRepository
    private let engine: AudioTapEngine
    // `@Published` so the rows redraw when a volume, mute or favorite changes.
    // These used to be plain properties: the UI only refreshed because the meter
    // levels happened to publish twelve times a second on this same object.
    @Published private var appPreferences: [String: AppVolumePreference]
    @Published private var favoriteBundleIDs: Set<String>
    private var warmRouteCache = WarmRouteCache(retention: 20)
    private var warmBundleIDs: Set<String> = []
    private var appSessions: [MixerSession] = []
    @Published private var capturingBundleIDs: Set<String> = []
    private var refreshTimer: Timer?
    private var pendingEventRefresh: DispatchWorkItem?
    private var pendingPreferenceSave: DispatchWorkItem?
    private var hasStarted = false

    /// A recovery scan only: Core Audio listeners drive the immediate refresh.
    private static let recoveryScanInterval: TimeInterval = 5
    /// Core Audio can emit a burst of notifications when several processes start
    /// or stop together. One rescan for the burst is enough.
    private static let eventCoalescingInterval: TimeInterval = 0.15
    /// Dragging a slider must not write JSON to `UserDefaults` on every tick.
    private static let preferenceSaveDebounce: TimeInterval = 0.5

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
            self?.levels.update(levels.mapValues(Double.init))
        }
        engine.onRoutingIssueChange = { [weak self] issue in
            self?.routingIssue = issue
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // The stored flag is only a mirror of the real login-item registration,
        // which the user can also change from System Settings.
        let registeredAsLoginItem = LoginItemService.isEnabled
        if settings.launchAtLogin != registeredAsLoginItem {
            settings.launchAtLogin = registeredAsLoginItem
            saveSettings()
        }

        hardwareObserver.start()
        refresh()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.recoveryScanInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // The default run-loop mode stops firing while a menu or a slider drag
        // is tracking, which is exactly when a stale list is most visible.
        refreshTimer.map { RunLoop.main.add($0, forMode: .common) }

        if settings.mixerEnabled {
            setMixerEnabled(true)
        }
    }

    /// Tears the audio routes down deterministically. Process exit does not run
    /// `deinit`, so without this the taps and aggregate devices are only cleaned
    /// up by Core Audio noticing the owning process is gone.
    func shutdown() {
        pendingEventRefresh?.cancel()
        pendingEventRefresh = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        hardwareObserver.stop()
        flushPendingPreferenceSave()
        engine.stop()
    }

    func refresh() {
        let devices = AudioHardware.outputDevices()
        if devices != outputDevices {
            outputDevices = devices
        }

        appSessions = AudioHardware.appSessions(
            excluding: Int32(ProcessInfo.processInfo.processIdentifier)
        )
        let playingSessions = appSessions.filter(\.isOutputRunning)
        warmBundleIDs = warmRouteCache.update(
            activeBundleIDs: Set(playingSessions.map(\.bundleID))
        )

        // Not warm-cached: protection has to lift as soon as the call ends, and
        // engage the moment it starts.
        let capturing = Set(appSessions.filter(\.isInputRunning).map(\.bundleID))
        if capturing != capturingBundleIDs {
            capturingBundleIDs = capturing
        }

        let merged = mergedSessions(with: playingSessions)
        if merged != sessions {
            sessions = merged
        }

        resolveOutputFallback()
        reconcileAudioRoutes()
    }

    func setMixerEnabled(_ enabled: Bool) {
        settings.mixerEnabled = enabled
        saveSettings()

        guard enabled else {
            engine.stop()
            levels.clear()
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
        saveSettingsSoon()
        reconcileAudioRoutes()
    }

    func setPreferredOutput(uid: String?) {
        settings.preferredOutputUID = uid
        saveSettings()
        resolveOutputFallback()
        reconcileAudioRoutes()
    }

    func setVolume(_ volume: Double, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var preference = appPreferences[bundleID] ?? AppVolumePreference()
        preference.volume = min(max(volume, 0), preference.maximumVolume)
        guard appPreferences[bundleID] != preference else { return }
        appPreferences[bundleID] = preference
        saveAppPreferencesSoon()
        reconcileAudioRoutes()
    }

    func setMuted(_ isMuted: Bool, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var preference = appPreferences[bundleID] ?? AppVolumePreference()
        preference.isMuted = isMuted
        appPreferences[bundleID] = preference
        saveAppPreferences()
        reconcileAudioRoutes()
    }

    func preference(for bundleID: String) -> AppVolumePreference {
        appPreferences[bundleID] ?? AppVolumePreference()
    }

    func setBoostEnabled(_ enabled: Bool, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var preference = appPreferences[bundleID] ?? AppVolumePreference()
        preference.boostEnabled = enabled
        // The stored volume is deliberately left alone; `appliedVolume` caps it
        // while boost is off, so re-enabling boost brings the level back.
        appPreferences[bundleID] = preference
        saveAppPreferences()
        reconcileAudioRoutes()
    }

    func isFavorite(_ bundleID: String) -> Bool {
        favoriteBundleIDs.contains(bundleID)
    }

    func setFavorite(_ isFavorite: Bool, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
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
            // Keep the toggle showing the real registration state rather than
            // the value the user just tried to set.
            settings.launchAtLogin = LoginItemService.isEnabled
            loginItemError = LoginItemService.failureMessage(for: error)
        }
    }

    func setAutoBypassWhileCapturing(_ enabled: Bool) {
        settings.autoBypassWhileCapturing = enabled
        saveSettings()
        reconcileAudioRoutes()
    }

    func setLimitPeaksWhenBoosting(_ enabled: Bool) {
        settings.limitPeaksWhenBoosting = enabled
        saveSettings()
        reconcileAudioRoutes()
    }

    /// The per-app switch shown on the row: take this app out of the mixer
    /// entirely, so it plays on its own route and nothing is re-rendered.
    func setBypassMixer(_ bypass: Bool, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var preference = appPreferences[bundleID] ?? AppVolumePreference()
        guard preference.bypassMixer != bypass else { return }
        preference.bypassMixer = bypass
        appPreferences[bundleID] = preference
        saveAppPreferences()
        reconcileAudioRoutes()
    }

    func isBypassingMixer(_ bundleID: String) -> Bool {
        StreamSafetyPolicy.bypassesMixer(
            bundleID: bundleID,
            bypassMixer: preference(for: bundleID).bypassMixer,
            autoBypassWhileCapturing: settings.autoBypassWhileCapturing,
            isCapturingAudio: capturingBundleIDs.contains(bundleID)
        )
    }

    /// The mixer is rendering an app that is capturing audio right now, so
    /// sharing a screen would feed its own audio back into the call.
    func warnsAboutEcho(_ bundleID: String) -> Bool {
        StreamSafetyPolicy.warnsAboutEcho(
            bundleID: bundleID,
            isBypassingMixer: isBypassingMixer(bundleID),
            isCapturingAudio: capturingBundleIDs.contains(bundleID)
        )
    }

    func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
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
        let message = result.usingFallback
            ? "A saída selecionada não está disponível. O mixer está usando a saída padrão do macOS."
            : nil
        if message != fallbackMessage {
            fallbackMessage = message
        }
    }

    private func reconcileAudioRoutes() {
        var protectedBundleIDs: Set<String> = []
        var targets: [RouteTarget] = []

        for session in appSessions where !session.processObjectIDs.isEmpty {
            guard !isBypassingMixer(session.bundleID) else {
                protectedBundleIDs.insert(session.bundleID)
                continue
            }

            let preference = preference(for: session.bundleID)
            // Route an app that is playing or was playing moments ago, and also
            // any app the user has explicitly muted or turned down. Holding the
            // route for those means the saved level is already in effect on the
            // first sample, instead of the app blaring at 100% until the tap is
            // built. Master volume alone does not pre-arm every idle app.
            let isConfigured = preference.isMuted || abs(preference.volume - 1) > 0.001
            guard warmBundleIDs.contains(session.bundleID) || isConfigured else { continue }

            let gain = preference.effectiveGain(masterVolume: settings.masterVolume)
            targets.append(
                RouteTarget(
                    id: session.bundleID,
                    displayName: session.displayName,
                    processObjectIDs: session.processObjectIDs,
                    gain: gain,
                    // Only while the mixer is actually amplifying. Below unity
                    // there is nothing to protect against.
                    limitPeaks: settings.limitPeaksWhenBoosting && gain > 1.0001
                )
            )
        }

        levels.removeLevels(forBundleIDs: protectedBundleIDs)
        engine.reconcile(targets: targets, outputDeviceUID: resolvedOutputUID)
    }

    private func mergedSessions(with playingSessions: [MixerSession]) -> [MixerSession] {
        var byBundleID: [String: MixerSession] = [:]
        for session in playingSessions {
            byBundleID[session.bundleID] = session
        }
        for bundleID in favoriteBundleIDs where byBundleID[bundleID] == nil {
            // Prefer the real process entry, so a favourite that is running but
            // silent still shows its proper name.
            byBundleID[bundleID] = appSessions.first { $0.bundleID == bundleID }
                ?? AudioHardware.inactiveSession(forFavorite: bundleID)
        }

        return byBundleID.values.sorted { lhs, rhs in
            let lhsIsFavorite = isFavorite(lhs.bundleID)
            let rhsIsFavorite = isFavorite(rhs.bundleID)
            if lhsIsFavorite != rhsIsFavorite { return lhsIsFavorite }
            if lhs.isOutputRunning != rhs.isOutputRunning { return lhs.isOutputRunning }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func scheduleEventRefresh() {
        guard hasStarted else { return }
        pendingEventRefresh?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.pendingEventRefresh = nil
            self?.refresh()
        }
        pendingEventRefresh = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.eventCoalescingInterval,
            execute: work
        )
    }

    /// Both stores are written together on purpose. A debounce that tracked
    /// settings and app preferences with one shared work item would drop a
    /// pending master-volume write as soon as an app slider moved.
    private func saveSettings() {
        persistNow()
    }

    private func saveSettingsSoon() {
        persistSoon()
    }

    private func saveAppPreferences() {
        persistNow()
    }

    private func saveAppPreferencesSoon() {
        persistSoon()
    }

    private func persistNow() {
        pendingPreferenceSave?.cancel()
        pendingPreferenceSave = nil
        repository.save(settings: settings)
        repository.save(appPreferences: appPreferences)
    }

    private func persistSoon() {
        pendingPreferenceSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPreferenceSave = nil
            self.repository.save(settings: self.settings)
            self.repository.save(appPreferences: self.appPreferences)
        }
        pendingPreferenceSave = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.preferenceSaveDebounce,
            execute: work
        )
    }

    private func flushPendingPreferenceSave() {
        guard pendingPreferenceSave != nil else { return }
        persistNow()
    }

    nonisolated static func canonicalizedAppPreferences(
        _ preferences: [String: AppVolumePreference]
    ) -> [String: AppVolumePreference] {
        var normalized: [String: AppVolumePreference] = [:]
        for (bundleID, preference) in preferences.sorted(by: { $0.key < $1.key }) {
            // A process that reports no bundle ID used to be stored under "".
            guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let canonicalBundleID = ProcessAppIdentity.canonicalBundleID(
                rawBundleID: bundleID,
                bundleURL: nil
            )
            // When a helper and its owning app both have stored preferences, the
            // one already written under the canonical ID wins.
            if canonicalBundleID == bundleID || normalized[canonicalBundleID] == nil {
                normalized[canonicalBundleID] = preferences[canonicalBundleID] ?? preference
            }
        }
        return normalized
    }

    nonisolated static func canonicalizedBundleIDs(_ bundleIDs: Set<String>) -> Set<String> {
        Set(
            bundleIDs
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { ProcessAppIdentity.canonicalBundleID(rawBundleID: $0, bundleURL: nil) }
        )
    }
}
