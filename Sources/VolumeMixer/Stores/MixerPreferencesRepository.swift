import Foundation

final class MixerPreferencesRepository {
    private enum Key {
        static let settings = "mixer.settings"
        static let appPreferences = "mixer.app-preferences"
        static let favoriteBundleIDs = "mixer.favorite-bundle-ids"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSettings() -> MixerAppSettings {
        decode(MixerAppSettings.self, forKey: Key.settings) ?? MixerAppSettings()
    }

    func save(settings: MixerAppSettings) {
        encode(settings, forKey: Key.settings)
    }

    func loadAppPreferences() -> [String: AppVolumePreference] {
        decode([String: AppVolumePreference].self, forKey: Key.appPreferences) ?? [:]
    }

    func save(appPreferences: [String: AppVolumePreference]) {
        encode(appPreferences, forKey: Key.appPreferences)
    }

    func loadFavoriteBundleIDs() -> Set<String> {
        decode(Set<String>.self, forKey: Key.favoriteBundleIDs) ?? []
    }

    func save(favoriteBundleIDs: Set<String>) {
        encode(favoriteBundleIDs, forKey: Key.favoriteBundleIDs)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
