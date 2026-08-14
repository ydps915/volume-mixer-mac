import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func install(with store: MixerStore) {
        guard statusItem == nil else { return }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "com.ydps915.VolumeMixer.status-item"
        statusItem.isVisible = true

        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image
        button.imagePosition = .imageOnly
        button.toolTip = "Volume Mixer"
        button.target = self
        button.action = #selector(togglePopover(_:))

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 330, height: 360)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(store)
        )

        self.statusItem = statusItem
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
