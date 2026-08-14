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
                .labelsHidden()
            }

            if store.sessions.isEmpty {
                Text("Nenhum áudio ativo")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.sessions.prefix(5)) { session in
                    let preference = store.preference(for: session.bundleID)
                    HStack(spacing: 8) {
                        Text(session.displayName)
                            .lineLimit(1)
                        Slider(
                            value: Binding(
                                get: { store.preference(for: session.bundleID).volume },
                                set: { store.setVolume($0, for: session.bundleID) }
                            ),
                            in: 0...1
                        )
                        .disabled(preference.isMuted)
                        Button {
                            store.setMuted(!preference.isMuted, for: session.bundleID)
                        } label: {
                            Image(systemName: preference.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        }
                        .buttonStyle(.borderless)
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
