import SwiftUI

@main
struct VolumeMixerApp: App {
    @StateObject private var store = MixerStore()

    var body: some Scene {
        WindowGroup("Volume Mixer", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Volume Mixer")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
