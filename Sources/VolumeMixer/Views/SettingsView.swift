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

                if let loginItemError = store.loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
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
