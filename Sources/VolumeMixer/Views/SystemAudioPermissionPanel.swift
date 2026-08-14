import SwiftUI

struct SystemAudioPermissionPanel: View {
    @EnvironmentObject private var store: MixerStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.systemAudioPermission.systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text("Permissão de áudio do sistema: \(store.systemAudioPermission.title)")
                    .font(.callout.weight(.semibold))
                Text(store.systemAudioPermission.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Verificar") {
                    store.checkSystemAudioPermission()
                }
                .disabled(store.systemAudioPermission == .checking)

                Button("Abrir Ajustes") {
                    store.openSystemSettings()
                }
                .buttonStyle(.link)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        switch store.systemAudioPermission {
        case .granted: .green
        case .required: .orange
        case .unknown, .checking: .secondary
        }
    }
}
