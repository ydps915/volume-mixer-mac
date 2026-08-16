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

    func testAutoBypassIsOffForSettingsFromEveryEarlierBuild() throws {
        // No Discord key at all.
        let plain = Data(#"{"masterVolume":0.8,"mixerEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(MixerAppSettings.self, from: plain)
        XCTAssertFalse(settings.autoBypassWhileCapturing)
        XCTAssertEqual(settings.masterVolume, 0.8)

        // The two shapes shipped before the per-app bypass replaced them. Both
        // made the choice global and automatic; neither is carried over.
        for legacy in [
            #"{"protectDiscordDuringStreams":true}"#,
            #"{"protectDiscordDuringStreams":false}"#,
            #"{"discordProtection":"always"}"#,
            #"{"discordProtection":"duringCallsAndStreams"}"#,
        ] {
            let decoded = try JSONDecoder().decode(
                MixerAppSettings.self,
                from: Data(legacy.utf8)
            )
            XCTAssertFalse(decoded.autoBypassWhileCapturing, "legacy: \(legacy)")
        }
    }

    func testAutoBypassRoundTrips() throws {
        let settings = MixerAppSettings(autoBypassWhileCapturing: true)
        let decoded = try JSONDecoder().decode(
            MixerAppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertTrue(decoded.autoBypassWhileCapturing)
    }

    func testDiscordStreamSafetyMatchesMainAppAndHelperBundleIDs() {
        XCTAssertTrue(StreamSafetyPolicy.isStreamSensitive(bundleID: "com.hnc.Discord"))
        XCTAssertTrue(StreamSafetyPolicy.isStreamSensitive(bundleID: "com.hnc.Discord.helper.Renderer"))
        XCTAssertFalse(StreamSafetyPolicy.isStreamSensitive(bundleID: "com.google.Chrome"))
    }

    func testDiscordStaysInTheMixerDuringACallByDefault() {
        // The whole point: a quiet microphone still needs the boost mid-call.
        XCTAssertFalse(StreamSafetyPolicy.bypassesMixer(
            bundleID: "com.hnc.Discord",
            bypassMixer: false,
            autoBypassWhileCapturing: false,
            isCapturingAudio: true
        ))
        // But the row says why it might want to be taken out.
        XCTAssertTrue(StreamSafetyPolicy.warnsAboutEcho(
            bundleID: "com.hnc.Discord",
            isBypassingMixer: false,
            isCapturingAudio: true
        ))
    }

    func testPerAppBypassWinsRegardlessOfCaptureState() {
        for capturing in [true, false] {
            XCTAssertTrue(StreamSafetyPolicy.bypassesMixer(
                bundleID: "com.hnc.Discord",
                bypassMixer: true,
                autoBypassWhileCapturing: false,
                isCapturingAudio: capturing
            ))
            // A bypassed app is already safe, so there is nothing to warn about.
            XCTAssertFalse(StreamSafetyPolicy.warnsAboutEcho(
                bundleID: "com.hnc.Discord",
                isBypassingMixer: true,
                isCapturingAudio: capturing
            ))
        }
        // The bypass is per app, so it works for anything, not just Discord.
        XCTAssertTrue(StreamSafetyPolicy.bypassesMixer(
            bundleID: "com.spotify.client",
            bypassMixer: true,
            autoBypassWhileCapturing: false,
            isCapturingAudio: false
        ))
    }

    func testOptionalAutoBypassOnlyAppliesToStreamSensitiveAppsWhileCapturing() {
        func bypasses(_ bundleID: String, capturing: Bool) -> Bool {
            StreamSafetyPolicy.bypassesMixer(
                bundleID: bundleID,
                bypassMixer: false,
                autoBypassWhileCapturing: true,
                isCapturingAudio: capturing
            )
        }

        XCTAssertTrue(bypasses("com.hnc.Discord", capturing: true))
        XCTAssertFalse(bypasses("com.hnc.Discord", capturing: false))
        // A different app capturing audio is not a screen-share echo risk for
        // the mixer, so it keeps its route.
        XCTAssertFalse(bypasses("com.google.Chrome", capturing: true))
    }

    func testNonCapturingAppNeverWarnsAboutEcho() {
        XCTAssertFalse(StreamSafetyPolicy.warnsAboutEcho(
            bundleID: "com.hnc.Discord",
            isBypassingMixer: false,
            isCapturingAudio: false
        ))
        XCTAssertFalse(StreamSafetyPolicy.warnsAboutEcho(
            bundleID: "com.spotify.client",
            isBypassingMixer: false,
            isCapturingAudio: true
        ))
    }

    func testBypassSurvivesAPreferenceRoundTrip() throws {
        let preference = AppVolumePreference(volume: 0.4, bypassMixer: true)
        let decoded = try JSONDecoder().decode(
            AppVolumePreference.self,
            from: try JSONEncoder().encode(preference)
        )
        XCTAssertTrue(decoded.bypassMixer)
        XCTAssertEqual(decoded.volume, 0.4, accuracy: 0.0001)

        // Preferences written before the bypass existed decode as "in the mixer".
        let legacy = try JSONDecoder().decode(
            AppVolumePreference.self,
            from: Data(#"{"volume":0.5,"isMuted":false,"boostEnabled":false}"#.utf8)
        )
        XCTAssertFalse(legacy.bypassMixer)
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
