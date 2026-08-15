import AppKit
import Foundation
import SwiftUI

struct AppMixerRow: View {
    @EnvironmentObject private var store: MixerStore
    let session: MixerSession

    var body: some View {
        let preference = store.preference(for: session.bundleID)
        let isFavorite = store.isFavorite(session.bundleID)
        let isProtectedFromCapture = store.isProtectedFromMixerCapture(session.bundleID)

        HStack(spacing: 12) {
            AppIcon(bundleID: session.bundleID)
                .frame(width: 28, height: 28)
                .opacity(session.isOutputRunning ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(statusText(preference: preference, isProtectedFromCapture: isProtectedFromCapture))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 145, alignment: .leading)

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { store.preference(for: session.bundleID).appliedVolume },
                        set: { store.setVolume($0, for: session.bundleID) }
                    ),
                    in: 0...preference.maximumVolume
                )
                .disabled(preference.isMuted || isProtectedFromCapture)
                .accessibilityLabel("Volume de \(session.displayName)")

                AudioLevelMeter(bundleID: session.bundleID)
            }

            Text("\(Int((preference.appliedVolume * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(preference.boostEnabled && preference.appliedVolume > 1 ? .orange : .secondary)
                .frame(width: 40, alignment: .trailing)

            Toggle(
                "Boost",
                isOn: Binding(
                    get: { store.preference(for: session.bundleID).boostEnabled },
                    set: { store.setBoostEnabled($0, for: session.bundleID) }
                )
            )
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(isProtectedFromCapture)
            .help("Permite aumentar este app até 200%. Pode causar distorção.")
            .accessibilityLabel("Boost de \(session.displayName)")

            Button {
                store.setMuted(!preference.isMuted, for: session.bundleID)
            } label: {
                Image(systemName: preference.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(preference.isMuted ? .orange : .primary)
            }
            .buttonStyle(.borderless)
            .disabled(isProtectedFromCapture)
            .help(preference.isMuted ? "Ativar som" : "Silenciar")
            .accessibilityLabel(preference.isMuted ? "Ativar som de \(session.displayName)" : "Silenciar \(session.displayName)")

            Button {
                store.setFavorite(!isFavorite, for: session.bundleID)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isFavorite ? "Remover dos favoritos" : "Favoritar app")
            .accessibilityLabel(isFavorite ? "Remover \(session.displayName) dos favoritos" : "Favoritar \(session.displayName)")
        }
        .padding(.vertical, 4)
    }

    private func statusText(
        preference: AppVolumePreference,
        isProtectedFromCapture: Bool
    ) -> String {
        if isProtectedFromCapture {
            return session.isInputRunning
                ? "Em chamada — fora do mixer para não dar eco"
                : "Protegido de streams"
        }
        if preference.isMuted { return "Silenciado" }
        if preference.boostEnabled && preference.appliedVolume > 1 { return "Boost ativado" }
        return session.isOutputRunning ? "Áudio ativo" : "Favorito — sem áudio"
    }
}

/// Draws with `Canvas` and observes only `AudioLevelStore`.
///
/// The previous implementation used `GeometryReader` plus an animated `Capsule`
/// overlay and read its value from `MixerStore`. Because every meter changed 12
/// times a second, and because the whole row observed the same object, AppKit
/// re-ran a full layout pass on the window continuously — roughly 40% of a core,
/// even with nothing playing. A `Canvas` redraw does not invalidate layout.
struct AudioLevelMeter: View {
    @EnvironmentObject private var levels: AudioLevelStore
    let bundleID: String

    var body: some View {
        let value = Self.visualLevel(levels.level(for: bundleID))

        Canvas(opaque: false) { context, size in
            let radius = size.height / 2
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius),
                with: .color(Color.secondary.opacity(0.2))
            )

            guard value > 0 else { return }
            let width = max(size.height, size.width * value)
            context.fill(
                Path(
                    roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height),
                    cornerRadius: radius
                ),
                with: .color(Self.color(for: value))
            )
        }
        .frame(height: 6)
        .accessibilityLabel("Nível de áudio")
        .accessibilityValue("\(Int((value * 100).rounded()))%")
    }

    /// Audio amplitude is logarithmic to the ear. A -54 dB to 0 dB display range
    /// keeps normal listening levels visible without masking silence.
    ///
    /// `nonisolated` because `View` conformance isolates the type to the main
    /// actor on some toolchains, which would otherwise make this pure function
    /// unreachable from tests.
    nonisolated static func visualLevel(_ level: Double) -> Double {
        let clampedLevel = min(max(level, 0), 1)
        guard clampedLevel > 0.0005 else { return 0 }
        let decibels = 20 * log10(clampedLevel)
        return min(max((decibels + 54) / 54, 0), 1)
    }

    private static func color(for value: Double) -> Color {
        if value >= 0.97 { return .red }
        if value >= 0.88 { return .orange }
        return .green
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let icon = AppIconCache.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Launch Services lookups and icon loading are expensive and were previously
/// repeated on every render of every row.
@MainActor
private enum AppIconCache {
    private static var icons: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard !misses.contains(bundleID) else { return nil }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        icons[bundleID] = icon
        return icon
    }
}
