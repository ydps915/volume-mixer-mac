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

            Section("Boost") {
                Toggle(
                    "Limitar picos ao usar boost",
                    isOn: Binding(
                        get: { store.settings.limitPeaksWhenBoosting },
                        set: { store.setLimitPeaksWhenBoosting($0) }
                    )
                )
                .tint(.blue)

                Text("Segura só os picos, sem mexer no resto. É o que permite deixar o boost alto para ouvir quem está com o microfone baixo sem estourar quando a pessoa fala mais alto.")
                    .foregroundStyle(.secondary)

                Text("Desligue apenas se quiser o ganho cru, sem nenhum tratamento.")
                    .foregroundStyle(.secondary)
            }

            Section("Chamadas e streams") {
                Text("Para mudar o volume de um app, o Volume Mixer precisa silenciá-lo e reproduzir o áudio dele. Quem passa a emitir o som é o Volume Mixer, e o compartilhamento de tela do Discord — que exclui apenas os processos do próprio Discord — não consegue excluir essa cópia. O resultado é eco: quem está na chamada se escuta.")
                    .foregroundStyle(.secondary)

                Text("O botão ⏻ na linha de cada app tira ele do mixer na hora, sem passar por aqui. Use antes de compartilhar a tela com som.")
                    .foregroundStyle(.secondary)

                Toggle(
                    "Tirar o Discord do mixer automaticamente em chamadas",
                    isOn: Binding(
                        get: { store.settings.autoBypassWhileCapturing },
                        set: { store.setAutoBypassWhileCapturing($0) }
                    )
                )
                .tint(.blue)

                Text("Desligado por padrão: isso também tira o boost que muita gente usa para ouvir quem está com o microfone baixo.")
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
