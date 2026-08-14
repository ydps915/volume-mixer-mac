import AppKit
import SwiftUI

struct AppMixerRow: View {
    @EnvironmentObject private var store: MixerStore
    let session: MixerSession

    var body: some View {
        let preference = store.preference(for: session.bundleID)
        let isFavorite = store.isFavorite(session.bundleID)

        HStack(spacing: 12) {
            AppIcon(bundleID: session.bundleID)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName)
                    .lineLimit(1)
                Text(statusText(preference: preference))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 145, alignment: .leading)

            Slider(
                value: Binding(
                    get: { store.preference(for: session.bundleID).volume },
                    set: { store.setVolume($0, for: session.bundleID) }
                ),
                in: 0...1
            )
            .disabled(preference.isMuted)

            Text("\(Int((preference.volume * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Button {
                store.setMuted(!preference.isMuted, for: session.bundleID)
            } label: {
                Image(systemName: preference.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)
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

    private func statusText(preference: AppVolumePreference) -> String {
        if preference.isMuted { return "Silenciado" }
        return session.isOutputRunning ? "Áudio ativo" : "Favorito — sem áudio"
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
