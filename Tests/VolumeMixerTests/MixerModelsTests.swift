import Foundation
import XCTest
@testable import VolumeMixer

final class MixerModelsTests: XCTestCase {
    func testMutedPreferenceHasZeroGain() {
        let preference = AppVolumePreference(volume: 0.7, isMuted: true)
        XCTAssertEqual(preference.effectiveGain(masterVolume: 0.5), 0)
    }

    func testPreferenceClampsVolumeAndAppliesMasterGain() {
        let preference = AppVolumePreference(volume: 2, isMuted: false)
        XCTAssertEqual(preference.volume, 1)
        XCTAssertEqual(preference.effectiveGain(masterVolume: 0.4), 0.4, accuracy: 0.0001)
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
        XCTAssertEqual(preference.volume, 1)
    }

    func testLegacySettingsEnableDiscordProtectionByDefault() throws {
        let data = Data(#"{"masterVolume":0.8,"mixerEnabled":true,"launchAtLogin":false}"#.utf8)
        let settings = try JSONDecoder().decode(MixerAppSettings.self, from: data)
        XCTAssertTrue(settings.protectDiscordDuringStreams)
        XCTAssertEqual(settings.masterVolume, 0.8)
    }

    func testDiscordStreamSafetyMatchesMainAppAndHelperBundleIDs() {
        XCTAssertTrue(StreamSafetyPolicy.excludesFromMixerCapture(bundleID: "com.hnc.Discord"))
        XCTAssertTrue(StreamSafetyPolicy.excludesFromMixerCapture(bundleID: "com.hnc.Discord.helper.Renderer"))
        XCTAssertFalse(StreamSafetyPolicy.excludesFromMixerCapture(bundleID: "com.google.Chrome"))
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
