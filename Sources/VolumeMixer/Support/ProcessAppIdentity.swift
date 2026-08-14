import AppKit
import Foundation

enum ProcessAppIdentity {
    static func canonicalBundleID(rawBundleID: String, bundleURL: URL?) -> String {
        if let outerApplicationURL = outerApplicationURL(for: bundleURL),
           let owningBundleID = Bundle(url: outerApplicationURL)?.bundleIdentifier {
            return owningBundleID
        }

        let normalizedBundleID = rawBundleID.lowercased()
        if normalizedBundleID.hasPrefix("com.google.chrome.") {
            return "com.google.Chrome"
        }
        if normalizedBundleID.hasPrefix("org.chromium.chromium.") {
            return "org.chromium.Chromium"
        }
        if normalizedBundleID.hasPrefix("com.hnc.discord.") {
            return "com.hnc.Discord"
        }
        return rawBundleID
    }

    static func displayName(
        rawBundleID: String,
        application: NSRunningApplication?
    ) -> String {
        if let outerApplicationURL = outerApplicationURL(for: application?.bundleURL) {
            return FileManager.default.displayName(atPath: outerApplicationURL.path)
        }
        return application?.localizedName ?? rawBundleID
    }

    static func outerApplicationURL(for bundleURL: URL?) -> URL? {
        guard let bundleURL else { return nil }
        let components = bundleURL.standardizedFileURL.pathComponents
        guard let outerApplicationIndex = components.firstIndex(where: {
            $0.lowercased().hasSuffix(".app")
        }) else {
            return nil
        }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...outerApplicationIndex])))
    }
}
