import Combine
import Foundation

/// Holds the live per-app meter levels, separately from `MixerStore`.
///
/// Levels change about twelve times a second. While they lived on `MixerStore`,
/// every view observing that object — rows, sliders, toggles, app icons — was
/// invalidated at the same rate.
@MainActor
final class AudioLevelStore: ObservableObject {
    @Published private(set) var levels: [String: Double] = [:]

    func level(for bundleID: String) -> Double {
        levels[bundleID] ?? 0
    }

    func update(_ newLevels: [String: Double]) {
        guard !Self.isEquivalent(levels, newLevels) else { return }
        levels = newLevels
    }

    func clear() {
        guard !levels.isEmpty else { return }
        levels = [:]
    }

    func removeLevels(forBundleIDs bundleIDs: Set<String>) {
        guard bundleIDs.contains(where: { levels[$0] != nil }) else { return }
        levels = levels.filter { !bundleIDs.contains($0.key) }
    }

    /// A difference the meter cannot draw is not worth a redraw.
    static func isEquivalent(_ lhs: [String: Double], _ rhs: [String: Double]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (bundleID, value) in lhs {
            guard let other = rhs[bundleID], abs(value - other) < 0.002 else { return false }
        }
        return true
    }
}
