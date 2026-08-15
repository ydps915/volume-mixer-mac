import Foundation
import XCTest
@testable import VolumeMixer

final class MixerModelsTests: XCTestCase {
    func testMutedPreferenceHasZeroGain() {
        let preference = AppVolumePreference(volume: 0.7, isMuted: true)
        XCTAssertEqual(preference.effectiveGain(masterVolume: 0.5), 0)
    }

    func testPreferenceCapsVolumeWithoutBoostAndAppliesMasterGain() {
        let preference = AppVolumePreference(volume: 2, isMuted: false)
        // The stored value survives so that re-enabling boost restores it, but
        // only 100% is in force while boost is off.
        XCTAssertEqual(preference.volume, 2)
        XCTAssertEqual(preference.appliedVolume, 1)
        XCTAssertEqual(preference.effectiveGain(masterVolume: 0.4), 0.4, accuracy: 0.0001)
    }

    func testTogglingBoostOffAndOnRestoresTheBoostedVolume() {
        var preference = AppVolumePreference(volume: 1.8, isMuted: false, boostEnabled: true)
        XCTAssertEqual(preference.appliedVolume, 1.8, accuracy: 0.0001)

        preference.boostEnabled = false
        XCTAssertEqual(preference.appliedVolume, 1)
        XCTAssertEqual(preference.effectiveGain(masterVolume: 1), 1, accuracy: 0.0001)

        preference.boostEnabled = true
        XCTAssertEqual(preference.appliedVolume, 1.8, accuracy: 0.0001)
        XCTAssertEqual(preference.effectiveGain(masterVolume: 1), 1.8, accuracy: 0.0001)
    }

    func testBoostAllowsPerAppGainUpToTwoHundredPercent() {
        let preference = AppVolumePreference(volume: 2, isMuted: false, boostEnabled: true)
        XCTAssertEqual(preference.maximumVolume, 2)
        XCTAssertEqual(preference.volume, 2)
        XCTAssertEqual(preference.effectiveGain(masterVolume: 1), 2, accuracy: 0.0001)
    }

    func testLegacyPreferencesDecodeWithoutBoost() throws {
        let data = Data(#"{"volume":1.5,"isMuted":false}"#.utf8)
        let preference = try JSONDecoder().decode(AppVolumePreference.self, from: data)
        XCTAssertFalse(preference.boostEnabled)
        XCTAssertEqual(preference.appliedVolume, 1)
        XCTAssertEqual(preference.effectiveGain(masterVolume: 1), 1, accuracy: 0.0001)
    }

    func testSettingsWithoutDiscordKeyUseAutomaticProtection() throws {
        let data = Data(#"{"masterVolume":0.8,"mixerEnabled":true,"launchAtLogin":false}"#.utf8)
        let settings = try JSONDecoder().decode(MixerAppSettings.self, from: data)
        XCTAssertEqual(settings.discordProtection, .duringCallsAndStreams)
        XCTAssertEqual(settings.masterVolume, 0.8)
    }

    func testLegacyDiscordBooleanMigratesToAMode() throws {
        // `true` meant "never route Discord at all".
        let alwaysData = Data(#"{"protectDiscordDuringStreams":true}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(MixerAppSettings.self, from: alwaysData).discordProtection,
            .always
        )

        // `false` left the user exposed to the screen-share echo, so it becomes
        // the automatic mode rather than `.never`.
        let offData = Data(#"{"protectDiscordDuringStreams":false}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(MixerAppSettings.self, from: offData).discordProtection,
            .duringCallsAndStreams
        )
    }

    func testDiscordProtectionModeRoundTrips() throws {
        let settings = MixerAppSettings(discordProtection: .never)
        let decoded = try JSONDecoder().decode(
            MixerAppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.discordProtection, .never)
    }

    func testDiscordStreamSafetyMatchesMainAppAndHelperBundleIDs() {
        XCTAssertTrue(StreamSafetyPolicy.isStreamSensitive(bundleID: "com.hnc.Discord"))
        XCTAssertTrue(StreamSafetyPolicy.isStreamSensitive(bundleID: "com.hnc.Discord.helper.Renderer"))
        XCTAssertFalse(StreamSafetyPolicy.isStreamSensitive(bundleID: "com.google.Chrome"))
    }

    func testAutomaticProtectionOnlyExcludesDiscordWhileItCapturesAudio() {
        func excludes(_ bundleID: String, capturing: Bool) -> Bool {
            StreamSafetyPolicy.excludesFromMixerCapture(
                bundleID: bundleID,
                mode: .duringCallsAndStreams,
                isCapturingAudio: capturing
            )
        }

        // In a call or sharing the screen: leave it alone, or the re-rendered
        // copy is fed straight back into the stream.
        XCTAssertTrue(excludes("com.hnc.Discord", capturing: true))
        // Idle: the user gets normal volume control.
        XCTAssertFalse(excludes("com.hnc.Discord", capturing: false))
        // Other apps are never affected, capturing or not.
        XCTAssertFalse(excludes("com.google.Chrome", capturing: true))
    }

    func testAlwaysAndNeverProtectionModesIgnoreCaptureState() {
        for capturing in [true, false] {
            XCTAssertTrue(StreamSafetyPolicy.excludesFromMixerCapture(
                bundleID: "com.hnc.Discord",
                mode: .always,
                isCapturingAudio: capturing
            ))
            XCTAssertFalse(StreamSafetyPolicy.excludesFromMixerCapture(
                bundleID: "com.hnc.Discord",
                mode: .never,
                isCapturingAudio: capturing
            ))
        }
    }

    func testWarmRouteCacheKeepsRecentlySilentAppReady() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        var cache = WarmRouteCache(retention: 20)

        XCTAssertEqual(
            cache.update(activeBundleIDs: ["com.example.Player"], now: startedAt),
            ["com.example.Player"]
        )
        XCTAssertEqual(
            cache.update(activeBundleIDs: [], now: startedAt.addingTimeInterval(19.9)),
            ["com.example.Player"]
        )
        XCTAssertTrue(
            cache.update(activeBundleIDs: [], now: startedAt.addingTimeInterval(20.1)).isEmpty
        )
    }

    func testWarmRouteCacheRefreshesTheWindowWhileStillPlaying() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        var cache = WarmRouteCache(retention: 20)

        _ = cache.update(activeBundleIDs: ["com.example.Player"], now: startedAt)
        _ = cache.update(
            activeBundleIDs: ["com.example.Player"],
            now: startedAt.addingTimeInterval(15)
        )
        // Still warm 25 s after it first started, because it was playing at 15 s.
        XCTAssertEqual(
            cache.update(activeBundleIDs: [], now: startedAt.addingTimeInterval(25)),
            ["com.example.Player"]
        )
    }

    func testCanonicalizationDropsEmptyBundleIDs() {
        let normalized = MixerStore.canonicalizedAppPreferences([
            "": AppVolumePreference(volume: 0.5),
            "com.example.Player": AppVolumePreference(volume: 0.25),
        ])

        XCTAssertNil(normalized[""])
        XCTAssertEqual(normalized["com.example.Player"]?.volume, 0.25)
        XCTAssertEqual(MixerStore.canonicalizedBundleIDs(["", "  ", "com.example.Player"]), ["com.example.Player"])
    }

    func testCanonicalPreferenceWinsOverHelperPreference() {
        let normalized = MixerStore.canonicalizedAppPreferences([
            "com.google.Chrome": AppVolumePreference(volume: 0.8),
            "com.google.Chrome.helper.Renderer": AppVolumePreference(volume: 0.35),
        ])

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized["com.google.Chrome"]?.volume, 0.8)
    }

    @MainActor
    func testLevelStoreIgnoresImperceptibleChanges() {
        let store = AudioLevelStore()
        store.update(["a": 0.5])
        XCTAssertEqual(store.level(for: "a"), 0.5)

        XCTAssertTrue(AudioLevelStore.isEquivalent(["a": 0.5], ["a": 0.5005]))
        XCTAssertFalse(AudioLevelStore.isEquivalent(["a": 0.5], ["a": 0.6]))
        XCTAssertFalse(AudioLevelStore.isEquivalent(["a": 0.5], ["a": 0.5, "b": 0.1]))

        store.removeLevels(forBundleIDs: ["a"])
        XCTAssertEqual(store.level(for: "a"), 0)
    }

    func testMeterUsesPerceptualDecibelScale() {
        XCTAssertEqual(AudioLevelMeter.visualLevel(0), 0)
        XCTAssertEqual(AudioLevelMeter.visualLevel(1), 1, accuracy: 0.0001)
        // -54 dBFS is the bottom of the displayed range.
        XCTAssertEqual(AudioLevelMeter.visualLevel(pow(10, -54.0 / 20)), 0, accuracy: 0.001)
        // Half amplitude is about -6 dBFS, near the top of a perceptual scale.
        XCTAssertEqual(AudioLevelMeter.visualLevel(0.5), 0.888, accuracy: 0.01)
    }

    func testHelperProcessesResolveToTheirOwningApp() {
        let chromeHelperURL = URL(fileURLWithPath:
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app"
        )
        XCTAssertEqual(
            ProcessAppIdentity.outerApplicationURL(for: chromeHelperURL)?.path,
            "/Applications/Google Chrome.app"
        )
        XCTAssertEqual(
            ProcessAppIdentity.canonicalBundleID(
                rawBundleID: "com.google.Chrome.helper.Renderer",
                bundleURL: nil
            ),
            "com.google.Chrome"
        )
    }

    @MainActor
    func testLegacyHelperPreferencesMigrateToChrome() {
        let suiteName = "VolumeMixerMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = MixerPreferencesRepository(defaults: defaults)

        repository.save(appPreferences: [
            "com.google.Chrome.helper.Renderer": AppVolumePreference(volume: 0.35, isMuted: true),
        ])
        repository.save(favoriteBundleIDs: ["com.google.Chrome.helper.Renderer"])

        let store = MixerStore(repository: repository)
        XCTAssertEqual(store.preference(for: "com.google.Chrome").volume, 0.35)
        XCTAssertTrue(store.preference(for: "com.google.Chrome").isMuted)
        XCTAssertTrue(store.isFavorite("com.google.Chrome"))
    }

    func testOutputFallsBackToDefaultWhenPreferredDeviceIsUnavailable() {
        let result = OutputRouteResolver.resolvedOutputUID(
            preferredUID: "headphones",
            availableUIDs: ["speakers"],
            defaultUID: "speakers"
        )
        XCTAssertEqual(result.uid, "speakers")
        XCTAssertTrue(result.usingFallback)
    }

    func testOutputUsesPreferredDeviceWhenAvailable() {
        let result = OutputRouteResolver.resolvedOutputUID(
            preferredUID: "headphones",
            availableUIDs: ["speakers", "headphones"],
            defaultUID: "speakers"
        )
        XCTAssertEqual(result.uid, "headphones")
        XCTAssertFalse(result.usingFallback)
    }

    func testSettingsAndAppPreferencesRoundTrip() {
        let suiteName = "VolumeMixerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = MixerPreferencesRepository(defaults: defaults)

        let settings = MixerAppSettings(
            masterVolume: 0.6,
            preferredOutputUID: "headphones",
            mixerEnabled: true,
            launchAtLogin: true
        )
        let preferences = ["com.example.Player": AppVolumePreference(volume: 0.25, isMuted: false)]
        let favorites: Set<String> = ["com.example.Player"]

        repository.save(settings: settings)
        repository.save(appPreferences: preferences)
        repository.save(favoriteBundleIDs: favorites)

        XCTAssertEqual(repository.loadSettings(), settings)
        XCTAssertEqual(repository.loadAppPreferences(), preferences)
        XCTAssertEqual(repository.loadFavoriteBundleIDs(), favorites)
    }

    func testActivationRequiresSupportedMacOSAndPermission() {
        XCTAssertTrue(MixerActivationPolicy.canActivate(
            osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0),
            permissionGranted: true
        ))
        XCTAssertFalse(MixerActivationPolicy.canActivate(
            osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0),
            permissionGranted: true
        ))
        XCTAssertFalse(MixerActivationPolicy.canActivate(
            osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0),
            permissionGranted: false
        ))
    }
}
