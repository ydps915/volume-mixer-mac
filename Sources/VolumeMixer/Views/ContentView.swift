import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: MixerStore

    private let systemDefaultTag = "system-default"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            sessionList
        }
        .task {
            store.start()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text("Volume Mixer")
                    .font(.title2.weight(.semibold))
                Text("Controle o volume de cada app em um só lugar.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(
                "Mixer ativo",
                isOn: Binding(
                    get: { store.settings.mixerEnabled },
                    set: { store.setMixerEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Mixer ativo")
        }
        .padding(20)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            SystemAudioPermissionPanel()

            if let message = store.engineState.message {
                Label(message, systemImage: statusIcon)
                    .font(.callout)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            }

            if let fallbackMessage = store.fallbackMessage {
                Label(fallbackMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Saída")
                    .frame(width: 70, alignment: .leading)
                Picker("Saída", selection: outputSelection) {
                    Text("Padrão do sistema").tag(systemDefaultTag)
                    ForEach(store.outputDevices) { device in
                        Text(device.isDefault ? "\(device.name) (padrão)" : device.name)
                            .tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 12) {
                Text("Mestre")
                    .frame(width: 70, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { store.settings.masterVolume },
                        set: { store.setMasterVolume($0) }
                    ),
                    in: 0...1
                )
                Text("\(Int((store.settings.masterVolume * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var sessionList: some View {
        if store.sessions.isEmpty {
            ContentUnavailableView(
                "Nenhum app para mostrar",
                systemImage: "speaker.slash",
                description: Text("Inicie um áudio em qualquer app ou favorite-o para mantê-lo nesta lista.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                let favorites = store.sessions.filter { store.isFavorite($0.bundleID) }
                let nonFavorites = store.sessions.filter { !store.isFavorite($0.bundleID) }

                if !favorites.isEmpty {
                    Section("Favoritos") {
                        ForEach(favorites) { session in
                            AppMixerRow(session: session)
                        }
                    }
                }

                if !nonFavorites.isEmpty {
                    Section("Com áudio ativo") {
                        ForEach(nonFavorites) { session in
                            AppMixerRow(session: session)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var outputSelection: Binding<String> {
        Binding(
            get: { store.settings.preferredOutputUID ?? systemDefaultTag },
            set: { store.setPreferredOutput(uid: $0 == systemDefaultTag ? nil : $0) }
        )
    }

    private var statusIcon: String {
        switch store.engineState {
        case .active: "checkmark.circle.fill"
        case .requestingPermission: "hourglass"
        case .permissionRequired, .unsupported, .failed: "exclamationmark.triangle.fill"
        case .inactive: "power"
        }
    }

    private var statusColor: Color {
        switch store.engineState {
        case .active: .green
        case .requestingPermission: .secondary
        case .permissionRequired, .unsupported, .failed: .orange
        case .inactive: .secondary
        }
    }
}
