import AppKit
import SwiftUI

@main
struct VolumeMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single `Window` rather than a `WindowGroup`: with a group, every
        // "Abrir Volume Mixer" from the menu bar created another mixer window
        // instead of focusing the one already open.
        Window("Volume Mixer", id: "main") {
            ContentView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.store.levels)
        }
        .defaultSize(width: 620, height: 560)
        .windowResizability(.contentMinSize)

        // A `MenuBarExtra` scene installs itself when the app launches. The
        // previous `NSStatusItem` was created from `ContentView.task`, so the
        // menu-bar control never appeared when the app started without a window
        // — which is exactly what happens when it is launched as a login item.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.store.levels)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Volume Mixer")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.store.levels)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = MixerStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
    }

    /// The mixer is a menu-bar app: closing the window must not end the session
    /// and drop every app back to full volume.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }
}
