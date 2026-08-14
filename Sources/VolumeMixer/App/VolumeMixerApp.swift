import SwiftUI

@main
struct VolumeMixerApp: App {
    @StateObject private var store = MixerStore()
    @StateObject private var menuBarController = MenuBarController()

    var body: some Scene {
        WindowGroup("Volume Mixer", id: "main") {
            ContentView()
                .environmentObject(store)
                .task {
                    menuBarController.install(with: store)
                }
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
