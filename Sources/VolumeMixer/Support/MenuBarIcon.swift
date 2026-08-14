import AppKit

enum MenuBarIcon {
    static let image: NSImage = {
        let fallback = NSImage(
            systemSymbolName: "slider.vertical.3",
            accessibilityDescription: "Volume Mixer"
        )!
        let image = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:)) ?? fallback
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
