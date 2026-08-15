import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MixerStore

    var body: some View {
        Form {
            Section("Geral") {
                Toggle(
                    "Iniciar ao entrar no Mac",
                    isOn: Binding(
                        get: { store.settings.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    )
                )
                .tint(.blue)

                if let loginItemError = store.loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Chamadas e streams") {
                Picker(
                    "Deixar o Discord fora do mixer",
                    selection: Binding(
                        get: { store.settings.discordProtection },
                        set: { store.setDiscordProtection($0) }
                    )
                ) {
                    ForEach(DiscordProtectionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text("Para mudar o volume de um app, o Volume Mixer precisa silenciá-lo e reproduzir o áudio dele. Quem passa a emitir o som é o Volume Mixer, e o compartilhamento de tela do Discord — que exclui apenas os processos do próprio Discord — não consegue excluir essa cópia. O resultado é eco: quem está na chamada se escuta.")
                    .foregroundStyle(.secondary)

                Text("Em “Durante chamadas e streams” o Discord sai do mixer só enquanto está capturando áudio, e você controla o volume dele no resto do tempo. Use “Nunca” apenas se você não compartilha tela com som.")
                    .foregroundStyle(.secondary)
            }

            Section("Privacidade") {
                Text("O Volume Mixer processa o áudio localmente, em tempo real. Nenhuma gravação é criada e nenhum áudio sai deste Mac.")
                SystemAudioPermissionPanel()
            }

            Section("Limitações do v1") {
                Text("Compatível com macOS 14.2 ou posterior. O mixer controla volume e mute por app e oferece uma única saída global estéreo.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}
