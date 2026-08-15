import AppKit

@MainActor
enum MenuBarIcon {
    /// Loaded from the app bundle's `Resources`, never from an SPM resource
    /// bundle: `Bundle.module` resolves to a path baked in at build time and
    /// traps with `fatalError` once the app is copied to another machine.
    static let image: NSImage = {
        let bundled = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
        let image = bundled ?? NSImage(
            systemSymbolName: "slider.vertical.3",
            accessibilityDescription: "Volume Mixer"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))

        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
