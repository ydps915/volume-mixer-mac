import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: MixerStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                .tint(.blue)
                .labelsHidden()
            }

            if store.sessions.isEmpty {
                Text("Nenhum áudio ativo")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.sessions.prefix(5)) { session in
                    let preference = store.preference(for: session.bundleID)
                    let isFavorite = store.isFavorite(session.bundleID)
                    let isProtectedFromCapture = store.isProtectedFromMixerCapture(session.bundleID)
                    HStack(spacing: 8) {
                        Text(session.displayName)
                            .lineLimit(1)
                        if isProtectedFromCapture {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .help("Protegido de chamadas e streams")
                        }
                        VStack(spacing: 3) {
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
                        Button {
                            store.setBoostEnabled(!preference.boostEnabled, for: session.bundleID)
                        } label: {
                            Text("2×")
                                .foregroundStyle(preference.boostEnabled ? .orange : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isProtectedFromCapture)
                        .help(preference.boostEnabled ? "Desativar boost" : "Permitir até 200%")
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
                        }
                        .buttonStyle(.borderless)
                        .disabled(isProtectedFromCapture)
                    }
                }
            }

            Divider()

            HStack {
                Button("Abrir Volume Mixer") {
                    openWindow(id: "main")
                }
                Spacer()
                SettingsLink {
                    Text("Preferências")
                }
            }
        }
        .padding(14)
        .frame(width: 330)
        .task { store.start() }
    }
}
