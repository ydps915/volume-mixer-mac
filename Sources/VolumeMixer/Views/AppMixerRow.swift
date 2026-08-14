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

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName)
                    .lineLimit(1)
                Text(statusText(preference: preference, isProtectedFromCapture: isProtectedFromCapture))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 145, alignment: .leading)

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { store.preference(for: session.bundleID).volume },
                        set: { store.setVolume($0, for: session.bundleID) }
                    ),
                    in: 0...preference.maximumVolume
                )
                .disabled(preference.isMuted || isProtectedFromCapture)

                AudioLevelMeter(level: store.level(for: session.bundleID))
            }

            Text("\(Int((preference.volume * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(preference.boostEnabled && preference.volume > 1 ? .orange : .secondary)
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

            Button {
                store.setMuted(!preference.isMuted, for: session.bundleID)
            } label: {
                Image(systemName: preference.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
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
        if isProtectedFromCapture { return "Protegido de streams" }
        if preference.isMuted { return "Silenciado" }
        if preference.boostEnabled && preference.volume > 1 { return "Boost ativado" }
        return session.isOutputRunning ? "Áudio ativo" : "Favorito — sem áudio"
    }
}

struct AudioLevelMeter: View {
    let level: Double

    private var visualLevel: Double {
        let clampedLevel = min(max(level, 0), 1)
        guard clampedLevel > 0.0005 else { return 0 }

        // Audio amplitude is logarithmic to the ear. A -54 dB to 0 dB display
        // range makes normal listening levels visible without masking silence.
        let decibels = 20 * log10(clampedLevel)
        return min(max((decibels + 54) / 54, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.green)
                        .frame(
                            width: visualLevel == 0
                                ? 0
                                : max(7, proxy.size.width * visualLevel)
                        )
                }
        }
        .frame(height: 6)
        .accessibilityLabel("Nível de áudio")
        .accessibilityValue("\(Int((visualLevel * 100).rounded()))%")
        .animation(.easeOut(duration: 0.12), value: visualLevel)
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
        }
    }
}
