import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: MixerStore
    @Environment(\.openWindow) private var openWindow

    private static let inlineSessionLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            if store.sessions.isEmpty {
                Text("Nenhum áudio ativo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                // Previously the popover rendered `prefix(5)` with no scrolling,
                // so any further app was silently unreachable from the menu bar.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.sessions) { session in
                            CompactMixerRow(session: session)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: scrollHeight)
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider()

            HStack {
                Button("Abrir Volume Mixer") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                SettingsLink {
                    Text("Preferências")
                }
                Button("Sair") {
                    NSApp.terminate(nil)
                }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Label("Volume Mixer", systemImage: "slider.horizontal.3")
                .font(.headline)
            Spacer()
            Toggle(
                "Mixer ativo",
                isOn: Binding(
                    get: { store.settings.mixerEnabled },
                    set: { store.setMixerEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.blue)
            .labelsHidden()
            .accessibilityLabel("Mixer ativo")
        }
    }

    private var scrollHeight: CGFloat {
        CGFloat(min(store.sessions.count, Self.inlineSessionLimit)) * 54
    }
}

private struct CompactMixerRow: View {
    @EnvironmentObject private var store: MixerStore
    let session: MixerSession

    var body: some View {
        let preference = store.preference(for: session.bundleID)
        let isFavorite = store.isFavorite(session.bundleID)
        let isBypassed = store.isBypassingMixer(session.bundleID)
        let isDisabled = preference.isMuted || isBypassed

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if store.warnsAboutEcho(session.bundleID) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(AppMixerRow.echoWarning)
                }

                Spacer(minLength: 4)

                Text("\(Int((preference.appliedVolume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(preference.boostEnabled && preference.appliedVolume > 1 ? .orange : .secondary)

                Button {
                    store.setBypassMixer(!preference.bypassMixer, for: session.bundleID)
                } label: {
                    Image(systemName: preference.bypassMixer ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(preference.bypassMixer ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help(
                    preference.bypassMixer
                        ? "Devolver \(session.displayName) ao mixer"
                        : "Tirar \(session.displayName) do mixer. \(AppMixerRow.echoWarning)"
                )
                .accessibilityLabel(
                    preference.bypassMixer
                        ? "Devolver \(session.displayName) ao mixer"
                        : "Tirar \(session.displayName) do mixer"
                )

                Button {
                    store.setBoostEnabled(!preference.boostEnabled, for: session.bundleID)
                } label: {
                    Text("2×")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(preference.boostEnabled ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(isBypassed)
                .help(preference.boostEnabled ? "Desativar boost" : "Permitir até 200%")
                .accessibilityLabel(
                    preference.boostEnabled
                        ? "Desativar boost de \(session.displayName)"
                        : "Ativar boost de \(session.displayName)"
                )

                Button {
                    store.setFavorite(!isFavorite, for: session.bundleID)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isFavorite ? "Remover dos favoritos" : "Favoritar app")
                .accessibilityLabel(isFavorite ? "Remover \(session.displayName) dos favoritos" : "Favoritar \(session.displayName)")

                Button {
                    store.setMuted(!preference.isMuted, for: session.bundleID)
                } label: {
                    Image(systemName: preference.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        .foregroundStyle(preference.isMuted ? .orange : .primary)
                }
                .buttonStyle(.borderless)
                .disabled(isBypassed)
                .help(preference.isMuted ? "Ativar som" : "Silenciar")
                .accessibilityLabel(preference.isMuted ? "Ativar som de \(session.displayName)" : "Silenciar \(session.displayName)")
            }

            Slider(
                value: Binding(
                    get: { store.preference(for: session.bundleID).appliedVolume },
                    set: { store.setVolume($0, for: session.bundleID) }
                ),
                in: 0...preference.maximumVolume
            )
            .controlSize(.small)
            .disabled(isDisabled)
            .accessibilityLabel("Volume de \(session.displayName)")

            AudioLevelMeter(bundleID: session.bundleID)
        }
    }
}
